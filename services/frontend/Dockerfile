# Stages: test (docker build --target test .) | deps -> runtime (default target)
FROM node:26-alpine AS deps
WORKDIR /app
COPY package*.json ./
# npm ci installs exactly what package-lock.json pins (npm install could drift).
RUN npm ci --omit=dev --no-audit --no-fund

# Syntax check, ESLint (eslint.config.js), then unit tests with coverage (node:test + supertest, test/*.test.js).
# CI runs this before building the image.
FROM node:26-alpine AS test
# pipefail so a failing `find` can't be hidden by xargs
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
WORKDIR /app
COPY package*.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN find src -name '*.js' -print0 | xargs -0 -n1 node --check && \
    npm run lint && \
    npm test

# Coverage report for SonarCloud: docker build --target coverage --output type=local,dest=out .
FROM scratch AS coverage
COPY --from=test /app/coverage/ /

FROM node:26-alpine
ENV NODE_ENV=production \
    NODE_OPTIONS="--require @opentelemetry/auto-instrumentations-node/register"
WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
USER 1000
EXPOSE 8080
CMD ["node", "src/server.js"]
