# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Telemetry collector (always runs: content capture is mandatory). Claude Code sends OTLP to it on
# 127.0.0.1; it writes everything to the telemetry bucket and sends two metrics to CloudWatch: the
# heartbeat (collector alive) and its S3 queue size (telemetry not leaving the box).
# Runs before the long installs so the heartbeat starts early.
OTELCOL_VERSION=0.162.0
OTELCOL_SHA256=4acec9ec5a676b443e636feae586add07edd204b790979dfafda5ccd7480cd53

curl -fsSL -o /tmp/otelcol-contrib.rpm \
  "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$OTELCOL_VERSION/otelcol-contrib_${OTELCOL_VERSION}_linux_amd64.rpm"
echo "$OTELCOL_SHA256  /tmp/otelcol-contrib.rpm" | sha256sum -c
dnf install -y /tmp/otelcol-contrib.rpm

s3_exporter() {   # $1 = signal
  cat <<EOF
  awss3/$1:
    marshaler: otlp_json
    s3uploader:
      region: $REGION
      s3_bucket: $TELEMETRY_BUCKET
      s3_prefix: claude-code/$OWNER/$1
      s3_partition_format: "year=%Y/month=%m/day=%d/hour=%H"
      compression: gzip
      unique_key_func_name: uuidv7
    # Kept on disk until the bucket accepts it (no retry time limit), up to 10,000 export requests - about
    # half a day of continuous use; the box stack alarms when the queue keeps growing
    sending_queue:
      enabled: true
      storage: file_storage
      queue_size: 10000
      batch:
        flush_timeout: 60s
    retry_on_failure:
      enabled: true
      max_elapsed_time: 0
EOF
}

{
cat <<EOF
extensions:
  health_check:
    endpoint: 127.0.0.1:13133
  file_storage:
    directory: /var/lib/otelcol-contrib/queue
    create_directory: true

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 127.0.0.1:4317
      http:
        endpoint: 127.0.0.1:4318
  hostmetrics:
    collection_interval: 60s
    scrapers:
      load: {}
  # The collector's own metrics (service.telemetry below)
  prometheus/self:
    config:
      scrape_configs:
        - job_name: otelcol
          scrape_interval: 60s
          static_configs:
            - targets: [127.0.0.1:8888]

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 20
  resourcedetection:
    detectors: [ec2, system]
    override: false
  resource/heartbeat:
    attributes:
      - { key: Owner, value: $OWNER, action: upsert }
      - { key: InstanceId, from_attribute: host.id, action: upsert }
  # Only the S3 queue size goes to CloudWatch
  filter/delivery:
    error_mode: ignore
    metrics:
      metric:
        - 'name != "otelcol_exporter_queue_size"'

exporters:
EOF
s3_exporter metrics
s3_exporter logs
s3_exporter traces
cat <<EOF
  # Per-box heartbeat; the box stack alarms if it stops while the instance is running
  awsemf/heartbeat:
    region: $REGION
    namespace: ClaudeScan
    log_group_name: $HEARTBEAT_LOG_GROUP
    log_stream_name: $OWNER
    dimension_rollup_option: NoDimensionRollup
    resource_to_telemetry_conversion:
      enabled: true
    metric_declarations:
      - dimensions: [[InstanceId, Owner]]
        metric_name_selectors: [system.cpu.load_average.1m]
      - dimensions: [[InstanceId, Owner, exporter]]
        metric_name_selectors: [otelcol_exporter_queue_size]

service:
  extensions: [health_check, file_storage]
  telemetry:
    metrics:
      readers:
        - pull:
            exporter:
              prometheus:
                host: 127.0.0.1
                port: 8888
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection]
      exporters: [awss3/metrics]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection]
      exporters: [awss3/logs]
    traces:
      receivers: [otlp]
      processors: [memory_limiter, resourcedetection]
      exporters: [awss3/traces]
    metrics/heartbeat:
      receivers: [hostmetrics]
      processors: [resourcedetection, resource/heartbeat]
      exporters: [awsemf/heartbeat]
    metrics/delivery:
      receivers: [prometheus/self]
      processors: [filter/delivery, resourcedetection, resource/heartbeat]
      exporters: [awsemf/heartbeat]
EOF
} > /etc/otelcol-contrib/config.yaml
otelcol-contrib validate --config=/etc/otelcol-contrib/config.yaml
# restart, not just start: a rerun of this module must load the new config
systemctl enable otelcol-contrib
systemctl restart otelcol-contrib
