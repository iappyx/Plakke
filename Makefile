APP      := Plakke
SIGN_ID  ?= -

.PHONY: app run test clean

# One bundler, shared with the release workflow — two would drift.
# VERSION defaults to 0.0.0-dev; the workflow sets it from the git tag.
app:
	@SIGN_ID="$(SIGN_ID)" ./build-app.sh

run: app
	open $(APP).app

# Local only — the Tests folder is not published.
test:
	@test -x ./Tests/run.sh && ./Tests/run.sh || echo "Tests/ is not present in this checkout."

clean:
	rm -rf .build $(APP).app
