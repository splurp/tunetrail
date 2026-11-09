# Tunetrail game server (server/), for Google Cloud Run or any Docker host.
#   docker build -t tunetrail-server .
#   docker run -p 8080:8080 -e DATABASE_URL=... tunetrail-server
FROM dart:stable AS build
WORKDIR /app
COPY packages/tunetrail_core packages/tunetrail_core
COPY server/pubspec.yaml server/pubspec.lock server/
WORKDIR /app/server
RUN dart pub get
COPY server/ /app/server/
RUN dart pub get --offline && dart compile exe bin/server.dart -o /app/tunetrail_server

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/tunetrail_server /app/tunetrail_server
ENV PORT=8080
EXPOSE 8080
CMD ["/app/tunetrail_server"]
