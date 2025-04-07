FROM python:3.13-slim AS secured_base

ENV BASE_WORK_DIR=/home
ENV WORK_DIR=${BASE_WORK_DIR}/app
ENV DOCKER_SCRIPTS_DIR=/var/docker_scripts

WORKDIR ${WORK_DIR}
ENV HOME=${WORK_DIR}

# Create non-root user and set up directories with proper permissions
COPY --chown=root:root ./container/add_user_group.sh ${DOCKER_SCRIPTS_DIR}/
RUN chmod 555 ${DOCKER_SCRIPTS_DIR}/* && \
    ${DOCKER_SCRIPTS_DIR}/add_user_group.sh && \
    rm ${DOCKER_SCRIPTS_DIR}/add_user_group.sh && \
    chown root:root ${BASE_WORK_DIR} && \
    chmod 775 ${BASE_WORK_DIR} && \
    mkdir -p ${WORK_DIR} && \
    chmod -R 750 ${WORK_DIR} && \
    chown -R dockerapp:dockerapp ${WORK_DIR}

# ------------------------------
FROM python:3.13-slim AS build

ARG PYTHON_MAIN_VERSION="3.13"
ARG POETRY_VERSION=2.0.1

ENV WORK_DIR=/home/app
WORKDIR ${WORK_DIR}

ENV PIP_DEFAULT_TIMEOUT=100 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    PYTHONFAULTHANDLER=1 \
    PYTHONHASHSEED=random \
    PYTHONUNBUFFERED=1 \
    VIRTUAL_ENV=${WORK_DIR}/.venv

# Install Poetry at system level (outside virtual environment)
# hadolint ignore=DL3013
RUN pip install --upgrade --root-user-action=ignore "poetry==${POETRY_VERSION}" poetry-plugin-export poetry-plugin-mono-repo-deps virtualenv pip==25.0.1

COPY ./package_a/pyproject.toml ./package_a/poetry.lock ./package_a/README.md ./package_a/
COPY ./package_a/package_a ./package_a/package_a/
COPY ./VERSION ./

# Build wheels for both packages
WORKDIR ${WORK_DIR}/package_a
RUN poetry --version && poetry build --output=/tmp/wheels

WORKDIR ${WORK_DIR}/package_a
# Export dependencies to requirements.txt without hashes
RUN poetry export --without-hashes --without dev --format requirements.txt --output requirements.txt && \
    echo "package_a" >> requirements.txt && \
    poetry build --output=/tmp/wheels

# Install project in virtual environment
RUN virtualenv ${VIRTUAL_ENV}
ENV PYTHONPATH=${VIRTUAL_ENV}/lib/python${PYTHON_MAIN_VERSION}/site-packages/
ENV PATH="$VIRTUAL_ENV/bin:$PATH"
# Install all packages from wheels and requirements
RUN python3 -m pip install --pre --no-cache-dir --find-links=/tmp/wheels/ \
    -r requirements.txt && \
    # Clean up unnecessary files to reduce image size
    find ${VIRTUAL_ENV} -type d -name "__pycache__" -exec rm -rf {} +

# ------------------------------
FROM secured_base AS api

ARG PYTHON_MAIN_VERSION="3.13"

ENV WORK_DIR=/home/app
WORKDIR ${WORK_DIR}
ENV HOME=${WORK_DIR}

ENV PYTHONFAULTHANDLER=1 \
    PYTHONHASHSEED=random \
    PYTHONUNBUFFERED=1 \
    VIRTUAL_ENV=${WORK_DIR}/.venv

# Copy virtual environment from build stage
COPY --chown=dockerapp:dockerapp --from=build ${VIRTUAL_ENV} ${VIRTUAL_ENV}
ENV PATH="${VIRTUAL_ENV}/bin:$PATH"
ENV PYTHONPATH=${VIRTUAL_ENV}/lib/python${PYTHON_MAIN_VERSION}/site-packages/

# Create logs directory with proper permissions
RUN mkdir -p "${WORK_DIR}/logs" && \
    chmod -R 750 "${WORK_DIR}/logs" && \
    chown -R dockerapp:dockerapp "${WORK_DIR}/logs"

# Copy configuration files
COPY --chown=dockerapp:dockerapp ./package_a/manage.py ${WORK_DIR}/

# Copy and setup entrypoint script
COPY --chown=root:root ./container/docker_entrypoint.sh /var/docker_scripts/
RUN chmod 555 /var/docker_scripts/* && \
    ln -s "/var/docker_scripts/docker_entrypoint.sh" /usr/local/bin/

# Switch to non-root user
USER dockerapp

# Add health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -f http://localhost:5000/health || exit 1

# Expose port
EXPOSE 5000

# Set entrypoint and default command
ENTRYPOINT ["docker_entrypoint.sh", "gunicorn", "manage:app"]
CMD ["-w", "4", "--preload", "--bind=0.0.0.0:5000", "-k", "uvicorn.workers.UvicornWorker"]
