# Upstream ships for Vercel (adapter-vercel) and publishes no image, so build it
# here with adapter-node. UPSTREAM_REF is pinned: bump it deliberately.
FROM node:24-slim AS build
ARG UPSTREAM_REPO=https://github.com/Metaphysics0/songsterr-downloader.git
ARG UPSTREAM_REF=a32438a9ddf3e86b7b09ec30d46e9fcb82c2e226
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/* && npm install -g bun@1.4.4
WORKDIR /src
RUN git init -q . && git fetch -q --depth 1 "$UPSTREAM_REPO" "$UPSTREAM_REF" && git checkout -q FETCH_HEAD
RUN bun install --frozen-lockfile && bun add -d @sveltejs/adapter-node@5 \
    && sed -i "s#@sveltejs/adapter-vercel#@sveltejs/adapter-node#; s#adapter({[^}]*})#adapter()#" svelte.config.js \
    && node ./node_modules/vite/bin/vite.js build \
    && rm -rf node_modules && bun install --production --ignore-scripts

FROM node:24-slim
ENV NODE_ENV=production HOST=0.0.0.0 PORT=3000
WORKDIR /app
COPY --from=build /src/build ./build
COPY --from=build /src/node_modules ./node_modules
COPY --from=build /src/package.json ./
USER node
EXPOSE 3000
CMD ["node", "build"]
