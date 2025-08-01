# This list must match the versions specified in
# uv/lib/dependabot/uv/language.rb: PRE_INSTALLED_PYTHON_VERSIONS_RAW
# Python versions are pinned to the release of each minor/patch version.
ARG PY_3_13=3.13.5
ARG PY_3_12=3.12.11
ARG PY_3_11=3.11.13
ARG PY_3_10=3.10.18
ARG PY_3_9=3.9.23
ARG PYENV_VERSION=v2.5.2

FROM ghcr.io/dependabot/dependabot-updater-core AS python-core
ARG PY_3_13
ARG PY_3_12
ARG PY_3_11
ARG PY_3_10
ARG PY_3_9
ARG PYENV_VERSION
USER root

COPY --chown=dependabot:dependabot uv/helpers /opt/python/helpers

# TODO: Now that switched from `pyenv install` which compiled from source to downloading / copying a pre-compiled python
# we could entirely drop pyenv if we change our ruby code that calls `pyenv exec` to track which version of python to
# call and uses the full python paths.
ENV PYENV_ROOT=/usr/local/.pyenv \
  PATH="/usr/local/.pyenv/bin:$PATH"
RUN mkdir -p "$PYENV_ROOT" && chown dependabot:dependabot "$PYENV_ROOT"
USER dependabot
ENV DEPENDABOT_NATIVE_HELPERS_PATH="/opt"
RUN git -c advice.detachedHead=false clone https://github.com/pyenv/pyenv.git --branch $PYENV_VERSION --single-branch --depth=1 /usr/local/.pyenv

# We used to use `pyenv install 3.x.y` but it's really slow because it compiles from source (~500s). So instead, we hack
# around that by downloading pre-compiled versions, then placing them where pyenv expects it in the `versions` subfolder.
# In the future, we should consider dropping pyenv completely, as it's mostly used here for legacy reasons...
# Although it is convenient when debugging to be able to quickly flip through environments.
RUN mkdir "${PYENV_ROOT}/versions"

## 3.9
# Docker doesn't support parametrizing `COPY --from:python:$PY_1_23-bookworm`, so work around it using an alias.
# TODO: If upstream adds support for Ubuntu, use that instead of Debian as the base suffix: https://github.com/docker-library/python/pull/791
FROM docker.io/library/python:$PY_3_9-bookworm AS upstream-python-3.9
FROM python-core AS python-3.9
ARG PYTHON_INSTALL_LOCATION="$PYENV_ROOT/versions/$PY_3_9"
COPY --from=upstream-python-3.9 --chown=dependabot:dependabot /usr/local/bin $PYTHON_INSTALL_LOCATION/bin
COPY --from=upstream-python-3.9 --chown=dependabot:dependabot /usr/local/include $PYTHON_INSTALL_LOCATION/include
COPY --from=upstream-python-3.9 --chown=dependabot:dependabot /usr/local/lib $PYTHON_INSTALL_LOCATION/lib
# `pip` and other scripts need their shebangs rewritten for the new location
RUN find $PYTHON_INSTALL_LOCATION/bin -type f -exec sed -i "1s|^#!/usr/local/bin/python|#!$PYTHON_INSTALL_LOCATION/bin/python|" {} +
# Ensure pyenv works and it's the python version we expect
RUN PYENV_VERSION=$PY_3_9 pyenv exec python --version | grep "Python $PY_3_9" || exit 1
RUN bash /opt/python/helpers/build $PY_3_9
# This python environment occupies ~0.5 GB and gets used for a fraction of jobs, so store it compressed.
RUN cd $PYENV_ROOT/versions \
  && tar -acf $PY_3_9.tar.zst $PY_3_9

## 3.10
# Docker doesn't support parametrizing `COPY --from:python:$PY_1_23-bookworm`, so work around it using an alias.
# TODO: If upstream adds support for Ubuntu, use that instead of Debian as the base suffix: https://github.com/docker-library/python/pull/791
FROM docker.io/library/python:$PY_3_10-bookworm AS upstream-python-3.10
FROM python-core AS python-3.10
ARG PYTHON_INSTALL_LOCATION="$PYENV_ROOT/versions/$PY_3_10"
COPY --from=upstream-python-3.10 --chown=dependabot:dependabot /usr/local/bin $PYTHON_INSTALL_LOCATION/bin
COPY --from=upstream-python-3.10 --chown=dependabot:dependabot /usr/local/include $PYTHON_INSTALL_LOCATION/include
COPY --from=upstream-python-3.10 --chown=dependabot:dependabot /usr/local/lib $PYTHON_INSTALL_LOCATION/lib
# `pip` and other scripts need their shebangs rewritten for the new location
RUN find $PYTHON_INSTALL_LOCATION/bin -type f -exec sed -i "1s|^#!/usr/local/bin/python|#!$PYTHON_INSTALL_LOCATION/bin/python|" {} +
# Ensure pyenv works and it's the python version we expect
RUN PYENV_VERSION=$PY_3_10 pyenv exec python --version | grep "Python $PY_3_10" || exit 1
RUN bash /opt/python/helpers/build $PY_3_10
# This python environment occupies ~0.5 GB and gets used for a fraction of jobs, so store it compressed.
RUN cd $PYENV_ROOT/versions \
  && tar -acf $PY_3_10.tar.zst $PY_3_10

## 3.11
# Docker doesn't support parametrizing `COPY --from:python:$PY_1_23-bookworm`, so work around it using an alias.
# TODO: If upstream adds support for Ubuntu, use that instead of Debian as the base suffix: https://github.com/docker-library/python/pull/791
FROM docker.io/library/python:$PY_3_11-bookworm AS upstream-python-3.11
FROM python-core AS python-3.11
ARG PYTHON_INSTALL_LOCATION="$PYENV_ROOT/versions/$PY_3_11"
COPY --from=upstream-python-3.11 --chown=dependabot:dependabot /usr/local/bin $PYTHON_INSTALL_LOCATION/bin
COPY --from=upstream-python-3.11 --chown=dependabot:dependabot /usr/local/include $PYTHON_INSTALL_LOCATION/include
COPY --from=upstream-python-3.11 --chown=dependabot:dependabot /usr/local/lib $PYTHON_INSTALL_LOCATION/lib
# `pip` and other scripts need their shebangs rewritten for the new location
RUN find $PYTHON_INSTALL_LOCATION/bin -type f -exec sed -i "1s|^#!/usr/local/bin/python|#!${PYTHON_INSTALL_LOCATION}/bin/python|" {} +
# Ensure pyenv works and it's the python version we expect
RUN PYENV_VERSION=$PY_3_11 pyenv exec python --version | grep "Python $PY_3_11" || exit 1
RUN bash /opt/python/helpers/build $PY_3_11
# This python environment occupies ~0.5 GB and gets used for a fraction of jobs, so store it compressed.
RUN cd $PYENV_ROOT/versions \
  && tar -acf $PY_3_11.tar.zst $PY_3_11

## 3.12
# Docker doesn't support parametrizing `COPY --from:python:$PY_1_23-bookworm`, so work around it using an alias.
# TODO: If upstream adds support for Ubuntu, use that instead of Debian as the base suffix: https://github.com/docker-library/python/pull/791
FROM docker.io/library/python:$PY_3_12-bookworm AS upstream-python-3.12
FROM python-core AS python-3.12
ARG PYTHON_INSTALL_LOCATION="$PYENV_ROOT/versions/$PY_3_12"
COPY --from=upstream-python-3.12 --chown=dependabot:dependabot /usr/local/bin $PYTHON_INSTALL_LOCATION/bin
COPY --from=upstream-python-3.12 --chown=dependabot:dependabot /usr/local/include $PYTHON_INSTALL_LOCATION/include
COPY --from=upstream-python-3.12 --chown=dependabot:dependabot /usr/local/lib $PYTHON_INSTALL_LOCATION/lib
# `pip` and other scripts need their shebangs rewritten for the new location
RUN find $PYTHON_INSTALL_LOCATION/bin -type f -exec sed -i "1s|^#!/usr/local/bin/python|#!${PYTHON_INSTALL_LOCATION}/bin/python|" {} +
# Ensure pyenv works and it's the python version we expect
RUN PYENV_VERSION=$PY_3_12 pyenv exec python --version | grep "Python $PY_3_12" || exit 1
RUN bash /opt/python/helpers/build $PY_3_12
# This python environment occupies ~0.5 GB and gets used for a fraction of jobs, so store it compressed.
RUN cd $PYENV_ROOT/versions \
  && tar -acf $PY_3_12.tar.zst $PY_3_12

## 3.13
# Docker doesn't support parametrizing `COPY --from:python:$PY_1_23-bookworm`, so work around it using an alias.
# TODO: If upstream adds support for Ubuntu, use that instead of Debian as the base suffix: https://github.com/docker-library/python/pull/791
FROM docker.io/library/python:$PY_3_13-bookworm AS upstream-python-3.13
FROM python-core AS python-3.13
ARG PYTHON_INSTALL_LOCATION="$PYENV_ROOT/versions/$PY_3_13"
COPY --from=upstream-python-3.13 --chown=dependabot:dependabot /usr/local/bin $PYTHON_INSTALL_LOCATION/bin
COPY --from=upstream-python-3.13 --chown=dependabot:dependabot /usr/local/include $PYTHON_INSTALL_LOCATION/include
COPY --from=upstream-python-3.13 --chown=dependabot:dependabot /usr/local/lib $PYTHON_INSTALL_LOCATION/lib
# `pip` and other scripts need their shebangs rewritten for the new location
RUN find $PYTHON_INSTALL_LOCATION/bin -type f -exec sed -i "1s|^#!/usr/local/bin/python|#!${PYTHON_INSTALL_LOCATION}/bin/python|" {} +
# Ensure pyenv works and it's the python version we expect
RUN PYENV_VERSION=$PY_3_13 pyenv exec python --version | grep "Python $PY_3_13" || exit 1
RUN bash /opt/python/helpers/build $PY_3_13
# This is the default Python, so no need to tar it

FROM python-core
# Install C-libs needed to build users' Python packages. Please document why each package is needed.
USER root
RUN apt-get update \
  && apt-get upgrade -y \
  && apt-get install -y --no-install-recommends \
    # Used by pycurl
    libcurl4-openssl-dev \
    # Used by mysqlclient
    libmysqlclient-dev \
    pkg-config \
    # Used by psycopg Postgres Client
    libpq-dev \
    # Used by python zoneinfo core lib
    tzdata \
    # Needed to build `gssapi`/`krb5`
    libkrb5-dev \
  && rm -rf /var/lib/apt/lists/*

USER dependabot

COPY --chown=dependabot:dependabot uv $DEPENDABOT_HOME/uv
COPY --chown=dependabot:dependabot common $DEPENDABOT_HOME/common
COPY --chown=dependabot:dependabot updater $DEPENDABOT_HOME/dependabot-updater

# Running these steps last means that if the builds in the concurrent stages take longer it doesn't block the pipeline until the end.
COPY --from=python-3.9 $PYENV_ROOT/versions/$PY_3_9.tar.zst $PYENV_ROOT/versions/$PY_3_9.tar.zst
COPY --from=python-3.10 $PYENV_ROOT/versions/$PY_3_10.tar.zst $PYENV_ROOT/versions/$PY_3_10.tar.zst
COPY --from=python-3.11 $PYENV_ROOT/versions/$PY_3_11.tar.zst $PYENV_ROOT/versions/$PY_3_11.tar.zst
COPY --from=python-3.12 $PYENV_ROOT/versions/$PY_3_12.tar.zst $PYENV_ROOT/versions/$PY_3_12.tar.zst
COPY --from=python-3.13 $PYENV_ROOT/versions/ $PYENV_ROOT/versions/

# Copy the output of the build script, it should be identical across Python versions
COPY --from=python-3.13 /opt/python/ /opt/python/

RUN pyenv global $PY_3_13

USER root

# Install Rust
ENV RUSTUP_HOME=/opt/rust \
  CARGO_HOME=/opt/rust \
  CARGO_REGISTRIES_CRATES_IO_PROTOCOL=sparse \
  PATH="${PATH}:/opt/rust/bin"
RUN mkdir -p "$RUSTUP_HOME" && chown dependabot:dependabot "$RUSTUP_HOME"

USER dependabot

COPY --from=rust /usr/local/rustup $RUSTUP_HOME
COPY --from=rust /usr/local/cargo $CARGO_HOME

# Configure cargo to use Git CLI so the Git shim works
RUN mkdir -p ~/.cargo && printf "[net]\ngit-fetch-with-cli = true\n" >> ~/.cargo/config.toml

# Install uv by copying from the official image
COPY --from=ghcr.io/astral-sh/uv:0.8.4 /uv /uvx /usr/local/bin/

COPY --chown=dependabot:dependabot cargo $DEPENDABOT_HOME/cargo
COPY --chown=dependabot:dependabot common $DEPENDABOT_HOME/common
COPY --chown=dependabot:dependabot updater $DEPENDABOT_HOME/dependabot-updater
