# syntax=docker/dockerfile:1

# ---------- build ----------
FROM node:22-alpine AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
# The API base URL is relative (/api) by default, so no build-time backend
# host is required. Override with a build arg only if you really need to.
ARG VITE_API_URL=""
ARG VITE_STRIPE_PUBLIC_KEY=""
ENV VITE_API_URL=${VITE_API_URL} \
    VITE_STRIPE_PUBLIC_KEY=${VITE_STRIPE_PUBLIC_KEY}

RUN npm run build

# ---------- serve ----------
FROM nginx:1.27-alpine AS runner

RUN rm -rf /usr/share/nginx/html/* /etc/nginx/conf.d/default.conf

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1/healthz || exit 1

CMD ["nginx", "-g", "daemon off;"]
