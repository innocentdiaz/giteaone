# Debian 12 image for Render (or any container host): install.sh does all the work.
FROM debian:bookworm-slim AS build
ARG RENDER_GIT_BRANCH
ARG RENDER_GIT_COMMIT
WORKDIR /src
COPY . .
RUN bash install.sh build

FROM debian:bookworm-slim
COPY --from=build /usr/local/bin/gitea /usr/local/bin/gitea
COPY install.sh /usr/local/lib/gitea/install.sh
RUN apt-get update -qq \
  && apt-get install -y -qq --no-install-recommends tini >/dev/null \
  && bash /usr/local/lib/gitea/install.sh runtime \
  && rm -rf /var/lib/apt/lists/*
ENV GITEA_WORK_DIR=/var/lib/gitea
EXPOSE 3000
CMD ["bash", "/usr/local/lib/gitea/install.sh", "run"]
