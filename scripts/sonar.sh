#!/bin/sh
#
# Copyright (C) 2026  Henrique Almeida <me@h3nc4.com>
#
# This file is part of dev-base.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.
#
# Analyses against the shared SonarQube, one project per developer because
# Community Edition tracks a single branch per project.
set -e

# The repository is wherever the caller stands. Walking up from $0 landed in
# /usr/local, since that is where this is installed.

delete_after=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d) delete_after="1" ;;
    *)
      echo "usage: $0 [-d]" >&2
      exit 2
      ;;
  esac
  shift
done

# Defaulted so a workstation needs nothing but a token.
SONAR_HOST_URL="${SONAR_HOST_URL:-https://sonar.h3nc4.com}"
export SONAR_HOST_URL

if [ -z "${SONAR_TOKEN:-}" ]; then
  echo "SONAR_TOKEN is not set." >&2
  echo "Create one under My Account, Security at ${SONAR_HOST_URL} and export" >&2
  echo "it from your shell profile. The scanner reads it from the environment." >&2
  exit 1
fi

# The scanner's own key file, which also names the per-developer project. Guarded
# because reading it outside a repository failed with sed naming a missing file.
if [ ! -f sonar-project.properties ]; then
  echo "sonar-project.properties is not here, so there is no project to scan." >&2
  echo "Run this from the root of a repository that has one." >&2
  exit 1
fi
repo_key="$(sed -n 's/^sonar\.projectKey=//p' sonar-project.properties)"
if [ -z "${repo_key}" ]; then
  echo "sonar-project.properties names no sonar.projectKey." >&2
  exit 1
fi

sonar_scan_image="sonarsource/sonar-scanner-cli:12"

# Swap is left alone on purpose: pinning it to the cap shuts the container out
# of swap, which makes the scanner thrash the page cache instead.
scanner_java_opts="${SONAR_SCANNER_JAVA_OPTS:--Xmx1g}"
scanner_memory="${SONAR_SCANNER_MEMORY:-4g}"

# curl from inside the scanner image, keeping the token out of argv.
sonar_api() {
  # shellcheck disable=SC2086
  docker run --rm \
    ${SONAR_NETWORK:+--network=${SONAR_NETWORK}} \
    -e SONAR_HOST_URL -e SONAR_TOKEN \
    --entrypoint sh "${sonar_scan_image}" -c "$1"
}

project_key="${SONAR_PROJECT_KEY:-}"

if [ -z "${project_key}" ] && [ -z "${CI:-}" ]; then
  # Single quoted so the container's shell expands it, and api/users/current is internal.
  # shellcheck disable=SC2016
  sonar_login="$(sonar_api \
    'curl -s -u "${SONAR_TOKEN}:" "${SONAR_HOST_URL}/api/users/current"' 2>/dev/null |
    sed -n 's/.*"login" *: *"\([^"]*\)".*/\1/p' | head -n 1)"
  if [ -z "${sonar_login}" ]; then
    sonar_login="$(id -un)"
    echo "Could not read your SonarQube login, falling back to ${sonar_login}" >&2
  fi
  project_key="${repo_key}-dev-${sonar_login}"
fi

echo "Analysing against ${SONAR_HOST_URL}${project_key:+ as ${project_key}}"

# The gate comes out of the repository's own properties file, so a pre-push run and CI hold it
# to the same one. The scanner ignores the key, and without it the server default applies.
sonar_gate="${SONAR_GATE:-$(sed -n 's/^h3nc4\.gate=[[:space:]]*//p' sonar-project.properties | head -n 1)}"

# The gate is chosen per project, so the project has to exist first. Left to the
# scan it would be created under the default gate instead.
gate_key="${project_key:-$(sed -n 's/^sonar\.projectKey=//p' sonar-project.properties)}"
if [ -n "${sonar_gate}" ] && [ -n "${gate_key}" ]; then
  sonar_api "curl -s -o /dev/null -u \"\${SONAR_TOKEN}:\" \
     -X POST \"\${SONAR_HOST_URL}/api/projects/create\" \
     --data-urlencode project=${gate_key} --data-urlencode name=${gate_key}"
  code="$(sonar_api "curl -s -o /dev/null -w '%{http_code}' -u \"\${SONAR_TOKEN}:\" \
     -X POST \"\${SONAR_HOST_URL}/api/qualitygates/select\" \
     --data-urlencode projectKey=${gate_key} --data-urlencode gateName=${sonar_gate}")"
  case "${code}" in
    204) echo "Gate ${sonar_gate} selected for ${gate_key}" ;;
    *) echo "Warning: selecting ${sonar_gate} returned ${code}" >&2 ;;
  esac
fi

node_maxspace="${SONAR_NODE_MAXSPACE:-}"
if [ -z "${node_maxspace}" ] && [ -f package.json ]; then
  node_maxspace=2048
fi

if [ -n "${node_maxspace}" ]; then
  set -- -Dsonar.qualitygate.wait=true -Dsonar.javascript.node.maxspace="${node_maxspace}"
else
  set -- -Dsonar.qualitygate.wait=true
fi
if [ -n "${project_key}" ]; then
  set -- "$@" -Dsonar.projectKey="${project_key}"
fi

if [ -f "coverage-wasm.xml" ]; then
  sed -i "s|<source>/${repo_key}|<source>.|" coverage-wasm.xml
fi

scan_status=0
docker run --rm \
  --memory="${scanner_memory}" \
  ${SONAR_NETWORK:+--network=${SONAR_NETWORK}} \
  -e SONAR_HOST_URL -e SONAR_TOKEN \
  -e SONAR_SCANNER_JAVA_OPTS="${scanner_java_opts}" \
  -v "${HOST_ROOT:-${PWD}}:/usr/src" \
  "${sonar_scan_image}" "$@" || scan_status=$?

# Only a clean scan is cleaned up. A failure keeps its project, so the dashboard
# the scanner just named is still there to read.
if [ -n "${delete_after}" ] && [ -n "${project_key}" ] && [ "${scan_status}" -eq 0 ]; then
  code="$(sonar_api \
    "curl -s -o /dev/null -w '%{http_code}' -u \"\${SONAR_TOKEN}:\" \
       -X POST \"\${SONAR_HOST_URL}/api/projects/delete\" \
       --data-urlencode project=${project_key}")"
  case "${code}" in
    204) echo "Deleted project ${project_key}" ;;
    *) echo "Warning: deleting ${project_key} returned ${code}" >&2 ;;
  esac
fi

exit "${scan_status}"
