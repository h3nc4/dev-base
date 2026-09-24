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

# The flags this needs are in the README, and each check below names the one it wants.

set -e

USER_NAME="dev"

# The workspace is discovered rather than named, because this image serves every
# repository and each one mounts itself under its own name.
workspace="${WORKSPACE:-}"
if [ -z "${workspace}" ]; then
  workspace="$(find /workspaces -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)"
fi

if [ -z "${workspace}" ] || [ ! -d "${workspace}" ]; then
  echo "Error: no repository is mounted under /workspaces." >&2
  echo "Ensure the following flag is set in your run command:" >&2
  echo "  \`-v \${PWD}:/workspaces/<repository>\`" >&2
  exit 1
fi
cd "${workspace}"

if [ ! -S /var/run/docker.sock ]; then
  echo "Error: Docker socket /var/run/docker.sock not found." >&2
  echo "Ensure the following flag is set in your run command:" >&2
  echo "  \`-v /var/run/docker.sock:/var/run/docker.sock\`" >&2
  exit 1
fi

# HOST_UID_GID is expected to be in the format UID:GID
if [ -n "${HOST_UID_GID}" ]; then
  host_uid=$(echo "${HOST_UID_GID}" | cut -d: -f1)
  host_gid=$(echo "${HOST_UID_GID}" | cut -d: -f2)
elif [ -z "${DEVCONTAINER}" ]; then
  echo "HOST_UID_GID environment variable not set." >&2
  echo "Ensure the following flag is set in your run command:" >&2
  echo "  \`-e HOST_UID_GID=\$(id -u):\$(id -g)\`" >&2
  exit 1
fi

current_uid=$(id -u "${USER_NAME}")
current_gid=$(id -g "${USER_NAME}")
if [ -z "${DEVCONTAINER}" ]; then
  if [ "${host_gid}" != "${current_gid}" ] || [ "${host_uid}" != "${current_uid}" ]; then
    echo "Current UID:GID (${current_uid}:${current_gid}) differs from host (${host_uid}:${host_gid})"
    echo "Updating ${USER_NAME} user to match host..."
    # doas replaces PATH with its own even under keepenv, which dropped the entries
    # an image adds for its toolchain. switch-user.sh puts this one back.
    DEV_PATH="${PATH}"
    export DEV_PATH
    exec doas /usr/local/bin/switch-user.sh "${USER_NAME}" "${host_uid}" "${host_gid}" "$0" "$@"
  fi
fi

host_gid=$(stat -c '%g' /var/run/docker.sock)
current_gid=$(getent group docker | cut -d: -f3)
if [ "${host_gid}" != "${current_gid}" ]; then
  echo "Updating docker group GID to ${host_gid}..."
  doas groupmod -o -g "${host_gid}" docker
fi

# The hooks are committed files, so git is pointed at them rather than a package
# installing shims into .git/hooks.
if [ -d scripts/hooks ]; then
  git config core.hooksPath scripts/hooks || :
fi

# Whatever this repository needs beyond the shared setup, which is one or two
# lines each: a dependency fetch, or a toolchain the image cannot hold.
if [ -x scripts/dev-init.sh ]; then
  ./scripts/dev-init.sh
fi

doas mandb >/dev/null 2>&1

echo "Container initialized successfully."
echo "Run \`docker exec -it <container_name> bash\` to start developing."
exec "$@"
