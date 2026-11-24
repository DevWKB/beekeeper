# Builds bk on top of the GHC/cabal base image and runs the shell
# integration tests (test/shell) against bash, zsh, and fish.
#
# Build context is the repository root (see compose.yaml).
#
#   docker compose run --rm bk            # all shells
#   docker compose run --rm bk fish       # just fish
#   docker compose run --rm bk zsh bash   # a subset, in that order

# `bk-base` is the image built from Docker.base. compose.yaml binds this name to
# the `base` service so it is always built first.
FROM bk-base

# GHC used to build bk; any version installed in Docker.base works.
ARG GHC_VERSION=9.10.3

# The shells under test (bash is already in the base image).
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        zsh \
        fish \
        && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src

# Build dependencies in their own layer so editing bk's sources doesn't
# rebuild them. (`lib:bk`, not `exe:bk`: the executable depends on bk's own
# library, which can't be built until the sources are copied in.)
COPY bk.cabal LICENSE README.md Setup.hs ./
RUN cabal build -w ghc-${GHC_VERSION} --only-dependencies lib:bk

# Build bk and put it on the PATH.
COPY app ./app
COPY src ./src
RUN cabal build -w ghc-${GHC_VERSION} exe:bk && \
    cp "$(cabal list-bin -w ghc-${GHC_VERSION} exe:bk)" /usr/local/bin/bk

# Copy the tests last so editing them doesn't rebuild bk.
COPY test/shell /bk-tests

ENTRYPOINT ["bash", "/bk-tests/run.sh"]
CMD ["bash", "zsh", "fish"]
