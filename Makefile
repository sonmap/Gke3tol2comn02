.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help setup lint test test-mock test-negative test-dryrun test-live \
        python-test render report clean

help:  ## 사용 가능한 명령
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	 | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

setup:  ## config/env.sh 생성
	@test -f config/env.sh || { \
	  cp config/env.example.sh config/env.sh; \
	  chmod 600 config/env.sh; \
	  echo "config/env.sh 생성 완료. __CONFIRM__ 항목을 채우십시오."; }
	@echo "편집: vi config/env.sh"

lint:  ## 셸 구문 검사 (shellcheck 가 있으면 함께)
	@for f in bin/*.sh bin/client-gke-router tests/*.sh lib/*.sh; do \
	  bash -n "$$f" || exit 1; done
	@echo "bash -n 통과"
	@command -v shellcheck >/dev/null 2>&1 \
	  && shellcheck -x -S warning bin/*.sh tests/*.sh lib/*.sh bin/client-gke-router \
	  || echo "shellcheck 없음 — 건너뜀"
	@python3 -m py_compile python/sample_bq_autopilot.py && echo "Python 구문 통과"

python-test:  ## Python 단위 테스트
	@if python3 -m pytest --version >/dev/null 2>&1; then \
	  python3 -m pytest python/tests -q; \
	else \
	  echo "pytest 없음 — 셀프테스트로 대체"; \
	  python3 python/tests/selftest.py; fi

test-mock:  ## GCP 접속 없이 하네스 검증 (CI 기본)
	@MODE=mock bin/run-all.sh

test-negative:  ## 실패 주입 — 하네스가 장애를 잡아내는지 검증
	@tests/negative.sh

test: lint python-test test-mock test-negative  ## 로컬 전체 검증
	@echo
	@echo "로컬 검증 완료. 운영 확인은 make test-dryrun 으로 진행하십시오."

test-dryrun:  ## 운영 클러스터에 조회·dry-run 만 (안전)
	@MODE=dryrun bin/run-all.sh

test-live:  ## 실제 Pod/PV/PVC 생성 — 운영 승인 후에만
	@MODE=live I_UNDERSTAND_THIS_TOUCHES_PROD=yes bin/run-all.sh

render:  ## 매니페스트 렌더링 후 출력 경로 표시
	@bin/render.sh

report:  ## 최신 증적 집계
	@bin/report.sh

report-md:  ## 보고용 마크다운 표
	@bin/report.sh --md

clean:  ## 증적과 임시 파일 정리
	@find evidence -mindepth 1 ! -name '.gitkeep' -exec rm -rf {} + 2>/dev/null || true
	@find . -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
	@echo "정리 완료"
