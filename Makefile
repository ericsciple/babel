FLOW_COMMIT = 09669846b7a7ca5a6c23c12d56bb3bebdafd67e9
TEST262_COMMIT = 8688c4ab79059c3097098605e69f1ee5eda6c409

FORCE_PUBLISH = "@babel/runtime,@babel/runtime-corejs2,@babel/runtime-corejs3,@babel/standalone,@babel/preset-env-standalone"

# Fix color output until TravisCI fixes https://github.com/travis-ci/travis-ci/issues/7967
export FORCE_COLOR = true

SOURCES = packages codemods eslint

COMMA := ,
EMPTY :=
SPACE := $(EMPTY) $(EMPTY)
COMMA_SEPARATED_SOURCES = $(subst $(SPACE),$(COMMA),$(SOURCES))


.PHONY: build build-dist watch lint fix clean test-clean test-only test test-ci publish bootstrap

build: build-bundle
ifneq ("$(BABEL_COVERAGE)", "true")
	$(MAKE) build-standalone
endif

build-bundle: clean clean-lib
	yarn gulp build
	$(MAKE) generate-standalone generate-type-helpers
	# call build again as the generated files might need to be compiled again.
	yarn gulp build
	$(MAKE) build-typings
	$(MAKE) build-dist

build-bundle-ci: bootstrap-only
	$(MAKE) build-bundle

generate-standalone:
	yarn node packages/babel-standalone/scripts/generate.js

generate-type-helpers:
	yarn node packages/babel-types/scripts/generateTypeHelpers.js

build-typings: build-flow-typings build-typescript-typings

build-flow-typings:
	yarn node packages/babel-types/scripts/generators/flow.js > packages/babel-types/lib/index.js.flow

build-typescript-typings:
	yarn node packages/babel-types/scripts/generators/typescript.js > packages/babel-types/lib/index.d.ts

build-standalone: build-babel-standalone build-preset-env-standalone

build-standalone-ci: build-bundle-ci
	$(MAKE) build-standalone

build-babel-standalone:
	yarn gulp build-babel-standalone

build-preset-env-standalone:
	yarn gulp build-babel-preset-env-standalone

prepublish-build-standalone:
	BABEL_ENV=production IS_PUBLISH=true yarn gulp build-babel-standalone

prepublish-build-preset-env-standalone:
	BABEL_ENV=production IS_PUBLISH=true yarn gulp build-babel-preset-env-standalone

build-dist: build-polyfill-dist build-plugin-transform-runtime-dist

build-polyfill-dist:
	cd packages/babel-polyfill; \
	scripts/build-dist.sh

build-plugin-transform-runtime-dist:
	cd packages/babel-plugin-transform-runtime; \
	yarn node scripts/build-dist.js

build-no-bundle: clean clean-lib
	BABEL_ENV=development yarn gulp build-no-bundle
	# Ensure that build artifacts for types are created during local
	# development too.
	$(MAKE) generate-type-helpers
	$(MAKE) build-typings

watch: build-no-bundle
	BABEL_ENV=development yarn gulp watch

code-quality-ci: flowcheck-ci lint-ci

flowcheck-ci: bootstrap-flowcheck
	$(MAKE) flow

code-quality: flow lint

flow:
	yarn flow check --strip-root

bootstrap-flowcheck: bootstrap-only
	yarn gulp build-babel-types
	$(MAKE) build-typings

lint-ci: lint-js-ci lint-ts-ci

lint-js-ci: bootstrap-only
	$(MAKE) lint-js

lint-ts-ci: bootstrap-flowcheck
	$(MAKE) lint-ts

lint: lint-js lint-ts

lint-js:
	yarn eslint scripts $(SOURCES) '*.js' --format=codeframe

lint-ts:
	scripts/tests/typescript/lint.sh

fix: fix-json fix-js

fix-js:
	yarn eslint scripts $(SOURCES) '*.js' --format=codeframe --fix

fix-json:
	yarn prettier "{$(COMMA_SEPARATED_SOURCES)}/*/test/fixtures/**/options.json" --write --loglevel warn

clean: test-clean
	rm -f .npmrc
	rm -rf packages/babel-polyfill/browser*
	rm -rf packages/babel-polyfill/dist
	rm -rf coverage
	rm -rf packages/*/npm-debug*

test-clean:
	$(foreach source, $(SOURCES), \
		$(call clean-source-test, $(source)))

# Does not work on Windows; use "yarn jest" instead
test-only:
	BABEL_ENV=test ./scripts/test.sh
	$(MAKE) test-clean

test: lint test-only

test-ci: jest-ci

jest-ci: build-standalone-ci
	BABEL_ENV=test yarn jest --maxWorkers=4 --ci
	$(MAKE) test-clean

# Does not work on Windows
test-ci-coverage: SHELL:=/bin/bash
test-ci-coverage:
	BABEL_COVERAGE=true BABEL_ENV=test $(MAKE) bootstrap
	BABEL_ENV=test TEST_TYPE=cov ./scripts/test-cov.sh
	bash <(curl -s https://codecov.io/bash) -f coverage/coverage-final.json

bootstrap-flow:
	rm -rf build/flow
	mkdir -p build
	git clone --branch=master --single-branch --shallow-since=2018-11-01 https://github.com/facebook/flow.git build/flow
	cd build/flow && git checkout $(FLOW_COMMIT)

test-flow:
	yarn node scripts/tests/flow/run_babel_parser_flow_tests.js

test-flow-ci: build-bundle-ci bootstrap-flow
	$(MAKE) test-flow

test-flow-update-whitelist:
	yarn node scripts/tests/flow/run_babel_parser_flow_tests.js --update-whitelist

bootstrap-test262:
	rm -rf build/test262
	mkdir -p build
	git clone --branch=master --single-branch --shallow-since=2019-09-01 https://github.com/tc39/test262.git build/test262
	cd build/test262 && git checkout $(TEST262_COMMIT)

test-test262:
	yarn node scripts/tests/test262/run_babel_parser_test262.js

test-test262-ci: build-bundle-ci bootstrap-test262
	$(MAKE) test-test262

test-test262-update-whitelist:
	yarn node scripts/tests/test262/run_babel_parser_test262.js --update-whitelist

# Does not work on Windows
clone-license:
	./scripts/clone-license.sh

prepublish-build: clean-lib clean-runtime-helpers
	NODE_ENV=production BABEL_ENV=production $(MAKE) build
	$(MAKE) clone-license

prepublish:
	$(MAKE) bootstrap-only
	$(MAKE) prepublish-build
	$(MAKE) test

new-version:
	git pull --rebase
	yarn lerna version --force-publish=$(FORCE_PUBLISH)

# NOTE: Run make new-version first
publish: prepublish
	yarn lerna publish from-git
	$(MAKE) clean

publish-ci: prepublish
ifneq ("$(NPM_TOKEN)", "")
	echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > .npmrc
else
	echo "Missing NPM_TOKEN env var"
	exit 1
endif
	yarn lerna publish from-git --yes
	rm -f .npmrc
	$(MAKE) clean

publish-test:
ifneq ("$(I_AM_USING_VERDACCIO)", "I_AM_SURE")
	echo "You probably don't know what you are doing"
	exit 1
endif
	$(MAKE) prepublish-build
	yarn lerna version patch --force-publish=$(FORCE_PUBLISH)  --no-push --yes --tag-version-prefix="version-e2e-test-"
	yarn lerna publish from-git --registry http://localhost:4873 --yes --tag-version-prefix="version-e2e-test-"
	$(MAKE) clean

publish-eslint:
	$(call set-json-field, ./eslint/$(PKG)/package.json, private, false)
	cd eslint/$(PKG); yarn publish
	$(call set-json-field, ./eslint/$(PKG)/package.json, private, true)

bootstrap-only: lerna-bootstrap

yarn-install: clean-all
	yarn --ignore-engines

lerna-bootstrap: yarn-install
# todo: remove `-- -- --ignore-engines` in Babel 8
	yarn lerna bootstrap -- -- --ignore-engines

bootstrap: bootstrap-only
	$(MAKE) build

clean-lib:
	# TODO: Don't delete eslint/*/lib when they use src
	$(foreach source, $(SOURCES), \
		$(if $(filter-out $(source), eslint), \
			$(call clean-source-lib, $(source))))

clean-runtime-helpers:
	rm -f packages/babel-runtime/helpers/**/*.js
	rm -f packages/babel-runtime-corejs2/helpers/**/*.js
	rm -f packages/babel-runtime-corejs3/helpers/**/*.js
	rm -rf packages/babel-runtime-corejs2/core-js

clean-all:
	rm -rf node_modules
	rm -rf package-lock.json
	rm -rf .changelog

	$(foreach source, $(SOURCES), \
		$(call clean-source-all, $(source)))

	$(MAKE) clean

define clean-source-lib
	rm -rf $(1)/*/lib

endef

define clean-source-test
	rm -rf $(1)/*/test/tmp
	rm -rf $(1)/*/test-fixtures.json

endef

define clean-source-all
	# TODO: Don't delete eslint/*/lib when they use src
	$(if $(filter-out $1, eslint), $(call clean-source-lib, $1))
	rm -rf $(1)/*/node_modules
	rm -rf $(1)/*/package-lock.json

endef

define set-json-field
	yarn node -e "\
		require('fs').writeFileSync('$1'.trim(), \
			JSON.stringify({ ...require('$1'.trim()), $2: $3 }, null, 2) + '\\n' \
		)"
endef
