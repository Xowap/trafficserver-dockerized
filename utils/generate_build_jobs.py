#!/usr/bin/env python3
import json
import re
import sys
import os
import shutil
import subprocess
from datetime import datetime, timedelta, timezone

CLONE_PATH = "/tmp/ats-clone-metadata"

def run_git_cmd(args, cwd=None):
    try:
        res = subprocess.run(
            ["git"] + args,
            capture_output=True,
            text=True,
            cwd=cwd,
            check=True
        )
        return res.stdout.strip()
    except subprocess.CalledProcessError as e:
        sys.stderr.write(f"Git command failed: {' '.join(e.cmd)}\nError: {e.stderr}\n")
        return None

def get_recent_git_tags():
    """
    Clones the apache/trafficserver repo metadata using blob:none,
    filters the semantic version tags, and checks their commit dates
    to find tags updated in the past 6 months (180 days).
    """
    if os.path.exists(CLONE_PATH):
        shutil.rmtree(CLONE_PATH)

    sys.stderr.write("Cloning apache/trafficserver repository metadata (blob:none)...\n")
    clone_res = run_git_cmd([
        "clone",
        "--filter=blob:none",
        "--no-checkout",
        "https://github.com/apache/trafficserver.git",
        CLONE_PATH
    ])
    if clone_res is None:
        sys.stderr.write("Failed to clone repository metadata.\n")
        return []

    # Get list of all tags
    tags_raw = run_git_cmd(["tag", "-l"], cwd=CLONE_PATH)
    if not tags_raw:
        return []

    tags = tags_raw.splitlines()
    recent_tags = []
    six_months_ago = datetime.now(timezone.utc) - timedelta(days=180)

    for tag in tags:
        # Filter release semantic version tags (e.g. 10.1.2) - no release candidates or rc tags
        if not re.match(r'^\d+\.\d+\.\d+$', tag):
            continue

        # Get the commit date in ISO 8601 format (e.g., 2026-03-30T16:21:30-05:00)
        date_str = run_git_cmd(["log", "-1", "--format=%cI", tag], cwd=CLONE_PATH)
        if not date_str:
            continue

        try:
            commit_date = datetime.fromisoformat(date_str)
        except Exception:
            continue

        if commit_date >= six_months_ago:
            recent_tags.append(tag)

    # Sort tags descending by semantic version
    recent_tags.sort(key=lambda s: list(map(int, s.split('.'))), reverse=True)
    return recent_tags

def fetch_and_parse_dockerfile(tag):
    """
    Dynamically detects the newest Ubuntu release subdirectory under contrib/docker/ubuntu/,
    fetches the raw Dockerfile using git show, and parses versions.
    """
    # 1. Detect subdirectories under contrib/docker/ubuntu/ for this tag
    dirs_raw = run_git_cmd(["ls-tree", "-d", "--name-only", f"{tag}:contrib/docker/ubuntu/"], cwd=CLONE_PATH)
    if not dirs_raw:
        sys.stderr.write(f"contrib/docker/ubuntu directory not found on tag {tag}. Skipping.\n")
        return None

    # Sort subdirectories alphabetically and take the last/newest one (e.g. noble, oracular, plucky, etc.)
    ubuntu_releases = [d.strip() for d in dirs_raw.splitlines() if d.strip()]
    ubuntu_releases.sort()
    
    if not ubuntu_releases:
        sys.stderr.write(f"No Ubuntu release subdirectories found on tag {tag}. Skipping.\n")
        return None

    ubuntu_version = ubuntu_releases[-1]
    sys.stderr.write(f"Detected newest Ubuntu version for tag {tag}: {ubuntu_version}\n")

    # 2. Fetch Dockerfile from the detected folder
    content = run_git_cmd(["show", f"{tag}:contrib/docker/ubuntu/{ubuntu_version}/Dockerfile"], cwd=CLONE_PATH)
    if not content:
        sys.stderr.write(f"Dockerfile not found on tag {tag} in path contrib/docker/ubuntu/{ubuntu_version}/Dockerfile. Skipping.\n")
        return None

    # Parse versions
    versions = {
        "ATS_VERSION": tag,
        "UBUNTU_VERSION": ubuntu_version,
        "GO_VERSION": None,
        "LLVM_VERSION": "18", # Default fallback
        "QUICHE_VERSION": None,
        "NGHTTP3_VERSION": None,
        "NGTCP2_VERSION": None,
        "NGHTTP2_VERSION": None,
        "CURL_VERSION": None
    }
    
    # 1. Parse GO_VERSION
    m = re.search(r'go(\d+\.\d+\.\d+)\.linux', content)
    if m:
        versions["GO_VERSION"] = m.group(1)
    else:
        m = re.search(r'GO_VERSION=(\d+\.\d+\.\d+)', content)
        if m:
            versions["GO_VERSION"] = m.group(1)
            
    # 2. Parse LLVM_VERSION
    m = re.search(r'LLVM_VERSION=(\d+)', content)
    if m:
        versions["LLVM_VERSION"] = m.group(1)
        
    # 3. Parse QUICHE_VERSION
    m = re.search(r'git clone -b ([\w\.-]+) .*quiche\.git', content)
    if m:
        versions["QUICHE_VERSION"] = m.group(1)
        
    # 4. Parse NGHTTP3_VERSION
    m = re.search(r'git clone .* -b (v?[\d\.]+) .*nghttp3\.git', content)
    if m:
        versions["NGHTTP3_VERSION"] = m.group(1)
        
    # 5. Parse NGTCP2_VERSION
    m = re.search(r'git clone .* -b (v?[\d\.]+) .*ngtcp2\.git', content)
    if m:
        versions["NGTCP2_VERSION"] = m.group(1)
        
    # 6. Parse NGHTTP2_VERSION
    m = re.search(r'git clone .* -b (v?[\d\.]+) .*nghttp2\.git', content)
    if m:
        versions["NGHTTP2_VERSION"] = m.group(1)
        
    # 7. Parse CURL_VERSION
    m = re.search(r'git clone .* -b (curl-[^\s]+) .*curl\.git', content)
    if m:
        versions["CURL_VERSION"] = m.group(1)
        
    # Ensure all required versions are found, otherwise skip
    for k, v in versions.items():
        if v is None:
            sys.stderr.write(f"Could not parse {k} from tag {tag} Dockerfile. Skipping.\n")
            return None
            
    return versions

def main():
    recent_tags = get_recent_git_tags()
    sys.stderr.write(f"ATS Git tags updated in past 6 months: {recent_tags}\n")
    
    jobs = []
    
    for i, tag in enumerate(recent_tags):
        job_vars = fetch_and_parse_dockerfile(tag)
        if job_vars is None:
            continue
            
        # For the highest version, we also want to tag it as 'latest' (and 'latest-no-hwloc')
        is_highest = (i == 0)
        
        # We need two variants for each tag: default and no-hwloc
        for base in ["default", "no-hwloc"]:
            tag_list = []
            if base == "default":
                tag_list.append(f"xowap/trafficserver:{tag}")
                if is_highest:
                    tag_list.append("xowap/trafficserver:latest")
            else:
                tag_list.append(f"xowap/trafficserver:{tag}-no-hwloc")
                if is_highest:
                    tag_list.append("xowap/trafficserver:no-hwloc")
            
            jobs.append({
                "base": base,
                "tag": ",".join(tag_list),
                "ats_version": job_vars["ATS_VERSION"],
                "ubuntu_version": job_vars["UBUNTU_VERSION"],
                "go_version": job_vars["GO_VERSION"],
                "llvm_version": job_vars["LLVM_VERSION"],
                "quiche_version": job_vars["QUICHE_VERSION"],
                "nghttp3_version": job_vars["NGHTTP3_VERSION"],
                "ngtcp2_version": job_vars["NGTCP2_VERSION"],
                "nghttp2_version": job_vars["NGHTTP2_VERSION"],
                "curl_version": job_vars["CURL_VERSION"],
                "name": f"{tag} ({base})"
            })

    # Cleanup the clone
    if os.path.exists(CLONE_PATH):
        shutil.rmtree(CLONE_PATH)

    # Output JSON array of jobs
    print(json.dumps({"include": jobs}))

if __name__ == "__main__":
    main()
