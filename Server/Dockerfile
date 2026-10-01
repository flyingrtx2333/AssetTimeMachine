FROM swift:6.2-jammy AS build

WORKDIR /src
ARG ATM_BUILD_JOBS=2
COPY Package.swift ./
COPY Package.resolved ./
COPY Sources ./Sources
COPY Server ./Server

RUN swift build -c release --jobs ${ATM_BUILD_JOBS} --product AssetTimeMachineBacktestWorker \
 && swift build -c release --jobs ${ATM_BUILD_JOBS} --product AssetTimeMachineBacktestCompute

FROM build AS validation
COPY tools/fixtures/backtest-history ./tools/fixtures/backtest-history
COPY tools/research-results/NFCICREDIT_initial_release.csv tools/research-results/NFCILEVERAGE_initial_release.csv ./tools/research-results/
COPY tools/research-results/macro-vintages/alfred-initial-release ./tools/research-results/macro-vintages/alfred-initial-release
RUN swift test -c release --jobs ${ATM_BUILD_JOBS}

FROM swift:6.2-jammy

WORKDIR /app
RUN mkdir -p /data
COPY --from=build /src/.build/release/AssetTimeMachineBacktestWorker /app/AssetTimeMachineBacktestWorker
COPY --from=build /src/.build/release/AssetTimeMachineBacktestCompute /app/AssetTimeMachineBacktestCompute
COPY --from=build /src/.build/release/AssetTimeMachineBacktest_AssetTimeMachineBacktestCore.resources /app/AssetTimeMachineBacktest_AssetTimeMachineBacktestCore.resources

ENV BACKTEST_WORKER_HOST=0.0.0.0 \
    BACKTEST_WORKER_PORT=18080 \
    BACKTEST_STORAGE_DIR=/data \
    BACKTEST_COMPUTE_EXECUTABLE=/app/AssetTimeMachineBacktestCompute

EXPOSE 18080
VOLUME ["/data"]

CMD ["/app/AssetTimeMachineBacktestWorker"]
