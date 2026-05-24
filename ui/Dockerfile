# Multi-stage build for the attackrangelocal UI.
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json ./
RUN npm install --no-audit --no-fund --include=dev
COPY . .
RUN npm run build

# Slim runtime: install only production deps.
FROM node:22-alpine AS run
WORKDIR /app
ENV NODE_ENV=production HOST=0.0.0.0 PORT=4321
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY --from=build /app/dist ./dist
EXPOSE 4321
CMD ["node", "./dist/server/entry.mjs"]
