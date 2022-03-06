#!/usr/bin/env bash
#
# Starts three Prometheus servers scraping themselves and sidecars for each.
# Two query nodes are started and all are clustered together.

trap 'kill 0' SIGTERM

MINIO_ENABLED=${MINIO_ENABLED:-""}
MINIO_EXECUTABLE=${MINIO_EXECUTABLE:-"minio"}
MC_EXECUTABLE=${MC_EXECUTABLE:-"mc"}
PROMETHEUS_EXECUTABLE=${PROMETHEUS_EXECUTABLE:-"prometheus"}
THANOS_EXECUTABLE=${THANOS_EXECUTABLE:-"thanos"}
S3_ENDPOINT=""

if [ ! $(command -v "$PROMETHEUS_EXECUTABLE") ]; then
  echo "Cannot find or execute Prometheus binary $PROMETHEUS_EXECUTABLE, you can override it by setting the PROMETHEUS_EXECUTABLE env variable"
  exit 1
fi

if [ ! $(command -v "$THANOS_EXECUTABLE") ]; then
  echo "Cannot find or execute Thanos binary $THANOS_EXECUTABLE, you can override it by setting the THANOS_EXECUTABLE env variable"
  exit 1
fi


# Setup alert / rules config file.
cat >data/rules2.yml <<-EOF
	groups:
	  - name: example
	    rules:
	    - record: job:go_threads:sum
	      expr: sum(go_threads) by (job)
EOF

cat >data/rules3.yml <<-EOF
  groups:
  - name: example_record_rules
    interval: 1s
    rules:
    - record: test_absent_metric
      expr: absent(nonexistent{job='thanos-receive'})
EOF

cat >data/rules4.yml <<-EOF
groups:
  - name: "test"
    rules:
      - alert: test
        expr: vector(1)
        labels:
          team: "test"
          severity: critical
        annotations:
          summary: "test"

EOF

STORES=""

QUERIER_JAEGER_CONFIG=$(
  cat <<-EOF
		type: JAEGER
		config:
		  service_name: thanos-query
		  sampler_type: ratelimiting
		  sampler_param: 2
	EOF
)

REMOTE_WRITE_FLAGS=""
if [ -n "${STATELESS_RULER_ENABLED}" ]; then
  cat >data/rule-remote-write.yaml <<-EOF
  remote_write:
  - name: "receive-0"
    url: "http://127.0.0.1:10908/api/v1/receive"
    headers:
      THANOS-TENANT: testing-stateless-ruler
EOF

  REMOTE_WRITE_FLAGS="--remote-write.config-file data/rule-remote-write.yaml"
fi

# Start Thanos Ruler.
${THANOS_EXECUTABLE} rule \
  --data-dir data/ \
  --eval-interval "30s" \
  --rule-file "data/rules2.yml" \
  --rule-file "data/rules3.yml" \
  --rule-file "data/rules4.yml" \
  --alert.query-url "http://0.0.0.0:9090" \
  --query "http://0.0.0.0:10904" \
  --query "http://0.0.0.0:10914" \
  --http-address="0.0.0.0:19999" \
  --grpc-address="0.0.0.0:19998" \
  --label 'rule="true"' \
  --log.level=debug \
  --remote-write.config-file=data/rule-remote-write.yaml \
  ${OBJSTORECFG} &

STORES="${STORES} --store 127.0.0.1:19998"

sleep 0.5

echo "all started; waiting for signal"

wait
