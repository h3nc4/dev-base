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

################################################################################
FROM debian:13@sha256:9cc080028c43b27d2074d63a5f9caf7166d731494965616c1a6d2827a004585c AS base

# One name for every repository, so a prebuilt base can bake the user it creates.
ARG USER="dev"
ARG UID="1000"
ARG GID="1000"

ENV DEBIAN_FRONTEND=noninteractive

# Set before anything installs, so a repository building on this inherits it too.
# `copyright` stays for redistribution, and manual pages because mandb runs on start.
RUN printf '%s\n' \
  'path-exclude /usr/share/doc/*' \
  'path-include /usr/share/doc/*/copyright' \
  'path-exclude /usr/share/locale/*' \
  'path-include /usr/share/locale/en*' \
  'path-include /usr/share/locale/locale.alias' \
  >/etc/dpkg/dpkg.cfg.d/01-trim

RUN apt-get update -qq

RUN apt-get install --no-install-recommends -y -qq locales && \
  echo "en_US.UTF-8 UTF-8" >/etc/locale.gen && \
  locale-gen en_US.UTF-8 && \
  update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

RUN apt-get install --no-install-recommends -y -qq \
  bash-completion \
  ca-certificates \
  curl \
  file \
  git \
  gnupg \
  gosu \
  iputils-ping \
  iproute2 \
  jq \
  less \
  man-db \
  nano \
  net-tools \
  opendoas \
  openssh-client \
  procps \
  shellcheck \
  tini \
  tree \
  wget \
  yq

# Docker outside of Docker, which scripts/sonar.sh and every image build need.
RUN apt-get install --no-install-recommends -y -qq \
  docker-cli \
  docker-buildx

RUN apt-get install --no-install-recommends -y -qq \
  brotli \
  gzip \
  xz-utils

################################################################################
# The developing user and doas. GID 110 matches the docker group the socket
# usually carries, and entrypoint.sh corrects it at run time when it differs.
RUN addgroup --gid "${GID}" "${USER}"
RUN adduser --uid "${UID}" --gid "${GID}" \
  --shell "/bin/bash" --disabled-password "${USER}"
RUN addgroup --gid 110 docker && usermod -aG docker "${USER}"
RUN printf "permit nopass nolog keepenv %s as root\n" "${USER}" >/etc/doas.conf && \
  chmod 400 /etc/doas.conf && \
  printf "%s\nset -e\n%s\n" "#!/bin/sh" "doas \$@" >/usr/local/bin/sudo && \
  chmod a+rx /usr/local/bin/sudo

################################################################################
# The scripts every repository was carrying its own copy of.
COPY scripts/switch-user.sh /usr/local/bin/switch-user.sh
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/sonar.sh /usr/local/bin/sonar
RUN chmod +x /usr/local/bin/switch-user.sh /usr/local/bin/entrypoint.sh \
  /usr/local/bin/sonar

RUN apt-get clean && rm -rf /var/lib/apt/lists/*
RUN rm -rf /var/cache/* /var/log/* /tmp/*

# The locale definition sources locale-gen reads, 17MB, and it has already run.
# Generating another locale in a container built on this means installing them back.
RUN rm -rf /usr/share/i18n

# The exclusions above bind later installs alone, so what debian:13 shipped is still
# here. Removing it took the image from 495MB to 402MB.
RUN find /usr/share/locale -mindepth 1 -maxdepth 1 \
  ! -name 'en*' ! -name 'locale.alias' -exec rm -rf {} + && \
  find /usr/share/doc -mindepth 1 ! -type d ! -name copyright -delete && \
  find /usr/share/doc -mindepth 1 -type d -empty -delete

################################################################################
# Squashed, so a repository building on this inherits one layer rather than ten.
FROM scratch AS final

ARG USER="dev"
ENV USER="${USER}" \
  LANG="en_US.UTF-8" \
  LC_ALL="en_US.UTF-8"

COPY --from=base / /

USER "${USER}"
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["/usr/bin/sleep", "infinity"]
