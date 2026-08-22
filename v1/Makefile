.PHONY: up down demo test

up:
	bash scripts/up.sh

down:
	bash scripts/down.sh

demo:
	curl -fsS -X POST http://127.0.0.1:8080/demo \
		-H 'content-type: application/json' \
		-d '{"content":"hello from make"}'

test:
	python -m pytest -q
