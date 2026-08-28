# ONE Brain — MCP-API-Server.
#
# Bewusst schlank: nur Laufzeit, keine Build-Werkzeuge. Was nicht im Image ist,
# kann auch nicht missbraucht werden.

FROM node:20-alpine

WORKDIR /app

# Erst die Manifeste, dann der Code. So bleibt die Dependency-Schicht im Cache,
# solange sich nur der Quellcode aendert.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY src/ ./src/
COPY bin/ ./bin/
COPY migrations/ ./migrations/

# Nicht als root laufen. Das node-Image bringt den User bereits mit.
USER node

EXPOSE 3000

# Migrationen laufen vor dem Server, in derselben Anweisung: startet der Server,
# ist das Schema garantiert aktuell. Schlaegt die Migration fehl, startet er nicht.
CMD ["sh", "-c", "node bin/migrate.mjs up && node src/server.mjs"]
