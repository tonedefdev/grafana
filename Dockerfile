FROM node:16-alpine3.14 as js-builder

ENV NODE_OPTIONS=--max_old_space_size=8000

WORKDIR /grafana

COPY package.json yarn.lock .yarnrc.yml ./
COPY .yarn .yarn
COPY packages packages
COPY plugins-bundled plugins-bundled

RUN yarn install

COPY tsconfig.json .eslintrc .editorconfig .browserslistrc .prettierrc.js babel.config.json ./
COPY public public
COPY tools tools
COPY scripts scripts
COPY emails emails

ENV NODE_ENV production
RUN yarn build

FROM golang:1.17.3-alpine3.14 as go-builder

RUN apk add --no-cache gcc g++ make
RUN apk add -u go

WORKDIR /grafana

COPY go.mod go.sum embed.go Makefile build.go package.json ./
COPY cue cue
COPY packages/grafana-schema packages/grafana-schema
COPY public/app/plugins public/app/plugins
COPY pkg pkg
COPY scripts scripts
COPY cue.mod cue.mod
COPY .bingo .bingo

RUN go mod verify
RUN make build-go

# Final stage
FROM alpine:3.14.3 as build

LABEL maintainer="Grafana team <hello@grafana.com>"

ARG GF_UID="472"
ARG GF_GID="0"

ENV PATH="/usr/share/grafana/bin:$PATH" \
  GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
  GF_PATHS_DATA="/var/lib/grafana" \
  GF_PATHS_HOME="/usr/share/grafana" \
  GF_PATHS_LOGS="/var/log/grafana" \
  GF_PATHS_PLUGINS="/var/lib/grafana/plugins" \
  GF_PATHS_PROVISIONING="/etc/grafana/provisioning"

WORKDIR $GF_PATHS_HOME

RUN apk add --no-cache ca-certificates bash tzdata musl-utils
RUN apk add --no-cache openssl ncurses-libs ncurses-terminfo-base --repository=http://dl-cdn.alpinelinux.org/alpine/edge/main
RUN apk upgrade ncurses-libs ncurses-terminfo-base --repository=http://dl-cdn.alpinelinux.org/alpine/edge/main
RUN apk info -vv | sort

COPY conf ./conf

RUN if [ ! $(getent group "$GF_GID") ]; then \
  addgroup -S -g $GF_GID grafana; \
  fi

RUN export GF_GID_NAME=$(getent group $GF_GID | cut -d':' -f1) && \
  mkdir -p "$GF_PATHS_HOME/.aws" && \
  adduser -S -u $GF_UID -G "$GF_GID_NAME" grafana && \
  mkdir -p "$GF_PATHS_PROVISIONING/datasources" \
  "$GF_PATHS_PROVISIONING/dashboards" \
  "$GF_PATHS_PROVISIONING/notifiers" \
  "$GF_PATHS_PROVISIONING/plugins" \
  "$GF_PATHS_PROVISIONING/access-control" \
  "$GF_PATHS_LOGS" \
  "$GF_PATHS_PLUGINS" \
  "$GF_PATHS_DATA" && \
  cp "$GF_PATHS_HOME/conf/sample.ini" "$GF_PATHS_CONFIG" && \
  cp "$GF_PATHS_HOME/conf/ldap.toml" /etc/grafana/ldap.toml && \
  chown -R "grafana:$GF_GID_NAME" "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING" && \
  chmod -R 777 "$GF_PATHS_DATA" "$GF_PATHS_HOME/.aws" "$GF_PATHS_LOGS" "$GF_PATHS_PLUGINS" "$GF_PATHS_PROVISIONING"

COPY --from=go-builder /grafana/bin/*/grafana-server /grafana/bin/*/grafana-cli ./bin/
COPY --from=js-builder /grafana/public ./public
COPY --from=js-builder /grafana/tools ./tools

EXPOSE 3000

COPY ./packaging/docker/run.sh /run.sh

ARG GRAFANA_VERSION="latest"

USER root

RUN apk update && apk add -u bash

ARG GF_INSTALL_IMAGE_RENDERER_PLUGIN="false"

ARG GF_GID="0"
ENV GF_PATHS_PLUGINS="/var/lib/grafana-plugins"

RUN mkdir -p "$GF_PATHS_PLUGINS" && \
    chown -R grafana:${GF_GID} "$GF_PATHS_PLUGINS"

RUN if [ $GF_INSTALL_IMAGE_RENDERER_PLUGIN = "true" ]; then \
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/community" >> /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/main" >> /etc/apk/repositories && \
    echo "http://dl-cdn.alpinelinux.org/alpine/edge/testing" >> /etc/apk/repositories && \
    apk --no-cache  upgrade && \
    apk add --no-cache udev ttf-opensans chromium && \
    rm -rf /tmp/* && \
    rm -rf /usr/share/grafana/tools/phantomjs; \
fi

USER grafana

ENV GF_PLUGIN_RENDERING_CHROME_BIN="/usr/bin/chromium-browser"

RUN if [ $GF_INSTALL_IMAGE_RENDERER_PLUGIN = "true" ]; then \
    grafana-cli \
        --pluginsDir "$GF_PATHS_PLUGINS" \
        --pluginUrl https://github.com/grafana/grafana-image-renderer/releases/latest/download/plugin-linux-x64-glibc-no-chromium.zip \
        plugins install grafana-image-renderer; \
fi

ARG GF_INSTALL_PLUGINS=""

RUN if [ ! -z "${GF_INSTALL_PLUGINS}" ]; then \
    OLDIFS=$IFS; \
    IFS=','; \
    for plugin in ${GF_INSTALL_PLUGINS}; do \
        IFS=$OLDIFS; \
        if expr match "$plugin" '.*\;.*'; then \
            pluginUrl=$(echo "$plugin" | cut -d';' -f 1); \
            pluginInstallFolder=$(echo "$plugin" | cut -d';' -f 2); \
            grafana-cli --pluginUrl ${pluginUrl} --pluginsDir "${GF_PATHS_PLUGINS}" plugins install "${pluginInstallFolder}"; \
        else \
            grafana-cli --pluginsDir "${GF_PATHS_PLUGINS}" plugins install ${plugin}; \
        fi \
    done \
fi

FROM alpine:3.14.3

ARG GF_UID="472"
ARG GF_GID="0"

ENV PATH="/usr/share/grafana/bin:$PATH" \
  GF_PATHS_CONFIG="/etc/grafana/grafana.ini" \
  GF_PATHS_DATA="/var/lib/grafana" \
  GF_PATHS_HOME="/usr/share/grafana" \
  GF_PATHS_LOGS="/var/log/grafana" \
  GF_PATHS_PLUGINS="/var/lib/grafana/plugins" \
  GF_PATHS_PROVISIONING="/etc/grafana/provisioning"

USER root
WORKDIR /
COPY --from=build . /

WORKDIR /usr/share/grafana
USER grafana
ENTRYPOINT ["/run.sh"]