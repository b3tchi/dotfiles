# Run notes — spec-writing eval

**Tasks written:** 8, each following the mandatory 5-step structure (failing test → confirm fail → minimal impl → confirm pass → commit).

**Task sequencing (dependency-ordered bottom-up):**
1. URL validation (pure)
2. Slug minter (pure, collision retry)
3. `ShortLink` SQLAlchemy model under `src/models/`
4. Repository layer (sqlite-in-memory for unit tests)
5. Config + Pydantic schemas + FastAPI deps (incl. SSO-header `get_current_user`)
6. `POST /links` endpoint
7. `GET /go/{slug}` endpoint (replaces placeholder left in Task 6)
8. Alembic migration + migration-matches-model test

**Tradeoffs and decisions:**
- Shared model placed at `src/models/short_link.py` per README convention ("Shared models: `src/models/`"), not inside the service directory.
- Auth delegated to existing SSO middleware via an `X-Acme-User` header consumed by a `get_current_user` dep — avoids re-implementing SAML/JWT and is explicitly documented in the spec.
- Repository tests use SQLite in-memory; Postgres-specific behavior is covered by the Alembic migration test (Task 8) instead of requiring `pytest-postgres` to run for every unit test.
- Task 6 ships with a placeholder `resolve` that 404s so the app is importable; Task 7 replaces it — keeps each task independently committable.
- 302 (not 301) for redirects so future iterations can edit targets without cache poisoning.
