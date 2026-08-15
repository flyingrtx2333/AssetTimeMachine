FROM swift:6.2-jammy AS build

WORKDIR /src
COPY Package.swift ./
COPY AssetTimeMachine/Backtest ./AssetTimeMachine/Backtest
COPY Server ./Server

RUN swift build -c release --product AssetTimeMachineBacktestWorker \
 && swift build -c release --product AssetTimeMachineBacktestCompute

FROM swift:6.2-jammy

WORKDIR /app
RUN mkdir -p /data
COPY --from=build /src/.build/release/AssetTimeMachineBacktestWorker /app/AssetTimeMachineBacktestWorker
COPY --from=build /src/.build/release/AssetTimeMachineBacktestCompute /app/AssetTimeMachineBacktestCompute

ENV BACKTEST_WORKER_HOST=0.0.0.0 \
    BACKTEST_WORKER_PORT=18080 \
    BACKTEST_STORAGE_DIR=/data \
    BACKTEST_COMPUTE_EXECUTABLE=/app/AssetTimeMachineBacktestCompute

EXPOSE 18080
VOLUME ["/data"]

CMD ["/app/AssetTimeMachineBacktestWorker"]
