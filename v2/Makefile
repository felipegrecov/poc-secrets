.PHONY: up down demo rotate-postgres rotate-minio test

up:
	bash scripts/up.sh

down:
	bash scripts/down.sh

demo:
	curl -fsS -X POST http://127.0.0.1:8080/demo \
		-H 'content-type: application/json' \
		-d '{"content":"hello from make"}'

rotate-postgres:
	bash scripts/rotate-postgres.sh

rotate-minio:
	bash scripts/rotate-minio.sh

test:
	python -m pytest -q
