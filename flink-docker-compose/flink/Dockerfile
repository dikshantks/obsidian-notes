# ---------------------------------------------------------------------------
# Custom Flink image with all connector JARs baked in.
#
# We bake the JARs into the image (rather than volume-mounting them) so the
# user never has to download anything by hand — `docker compose up --build`
# produces a fully self-contained cluster. The same image is used for the
# JobManager, the TaskManager, and the one-shot CDC pipeline submitter.
# ---------------------------------------------------------------------------
ARG FLINK_VERSION=2.2.1-java21
FROM flink:${FLINK_VERSION}

# Flink 2.2 switches to a non-root 'flink' user; switch back to root so we
# can install JARs into /opt/flink/lib and create /opt/flink-cdc.
USER root

# Versions are pinned as build args so they are easy to bump in one place.
# These are mutually compatible on Flink 2.2 (see README for the matrix).
ARG ICEBERG_VERSION=1.11.0
# Iceberg's Flink module lags: iceberg-flink-runtime-2.1 is forward-compatible
# with Flink 2.2 (there is no 2.2 variant in Iceberg 1.11).
ARG ICEBERG_FLINK_MINOR=2.1
# FLINK_MINOR is the Flink-version suffix used in CDC artifact names (3.6.0-2.2).
ARG FLINK_MINOR=2.2
# MYSQL_CDC_VERSION: the combined version used for flink-sql-connector-mysql-cdc.
# This is the underlying MySQL CDC fat JAR — it provides MySqlSource, Debezium,
# and flink-shaded-guava31 which the pipeline connector depends on.
ARG MYSQL_CDC_VERSION=3.6.0-2.2
ARG MYSQL_DRIVER_VERSION=8.4.0
# flink-shaded-hadoop-2-uber: provides org.apache.hadoop.conf.Configuration and
# the rest of hadoop-common. Required at runtime by flink-cdc-pipeline-connector-iceberg
# (IcebergCommitter instantiates Hadoop Configuration directly). In Flink 2.x this
# JAR is no longer bundled in flink-dist, so we add it explicitly.
ARG HADOOP_UBER_VERSION=2.8.3-10.0
# Nessie's *native* Iceberg catalog (NessieCatalog). We use it instead of the
# Iceberg REST catalog for WRITES because Nessie's REST createTable currently
# throws a server-side NPE when the schema has identifier fields (i.e. any table
# with a PRIMARY KEY — which CDC upsert requires). The native catalog writes
# Iceberg metadata client-side and only stores a pointer in Nessie, sidestepping
# that bug. Trino still reads via Nessie's REST endpoint (the read path is fine).
# These jars are NOT bundled in iceberg-flink-runtime, so we add them explicitly.
# jackson/slf4j in the Flink dist are shaded/relocated, so nessie needs its own.
ARG NESSIE_VERSION=0.108.1
ARG MP_OPENAPI_VERSION=4.1.1
ARG JACKSON_VERSION=2.18.2

# Flink CDC Pipeline framework version. The full artifact suffix is
# ${FLINK_CDC_VERSION}-${FLINK_MINOR} (e.g. 3.6.0-2.2).
ARG FLINK_CDC_VERSION=3.6.0

ARG MAVEN=https://repo1.maven.org/maven2

# Flink loads any JAR placed in /opt/flink/lib onto the cluster classpath.
#   * iceberg-flink-runtime            : Iceberg source/sink + catalog integration
#   * iceberg-aws-bundle               : S3FileIO + AWS SDK, for MinIO
#   * flink-sql-connector-mysql-cdc    : MySQL CDC fat JAR (provides MySqlSource,
#                                        Debezium, flink-shaded-guava31); needed by
#                                        flink-cdc-pipeline-connector-mysql at runtime
#   * mysql-connector-j                : JDBC driver (licensing kept separate)
# Note: flink-shaded-hadoop-2-uber is NOT needed for Flink 2.x.
# curl is already present in the Flink base image.
RUN set -eux; \
    cd /opt/flink/lib; \
    curl -fSL -o iceberg-flink-runtime.jar \
      "${MAVEN}/org/apache/iceberg/iceberg-flink-runtime-${ICEBERG_FLINK_MINOR}/${ICEBERG_VERSION}/iceberg-flink-runtime-${ICEBERG_FLINK_MINOR}-${ICEBERG_VERSION}.jar"; \
    curl -fSL -o iceberg-aws-bundle.jar \
      "${MAVEN}/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar"; \
    curl -fSL -o flink-sql-connector-mysql-cdc.jar \
      "${MAVEN}/org/apache/flink/flink-sql-connector-mysql-cdc/${MYSQL_CDC_VERSION}/flink-sql-connector-mysql-cdc-${MYSQL_CDC_VERSION}.jar"; \
    curl -fSL -o mysql-connector-j.jar \
      "${MAVEN}/com/mysql/mysql-connector-j/${MYSQL_DRIVER_VERSION}/mysql-connector-j-${MYSQL_DRIVER_VERSION}.jar"; \
    curl -fSL -o iceberg-nessie.jar \
      "${MAVEN}/org/apache/iceberg/iceberg-nessie/${ICEBERG_VERSION}/iceberg-nessie-${ICEBERG_VERSION}.jar"; \
    curl -fSL -o nessie-client.jar \
      "${MAVEN}/org/projectnessie/nessie/nessie-client/${NESSIE_VERSION}/nessie-client-${NESSIE_VERSION}.jar"; \
    curl -fSL -o nessie-model.jar \
      "${MAVEN}/org/projectnessie/nessie/nessie-model/${NESSIE_VERSION}/nessie-model-${NESSIE_VERSION}.jar"; \
    curl -fSL -o microprofile-openapi-api.jar \
      "${MAVEN}/org/eclipse/microprofile/openapi/microprofile-openapi-api/${MP_OPENAPI_VERSION}/microprofile-openapi-api-${MP_OPENAPI_VERSION}.jar"; \
    curl -fSL -o jackson-core.jar \
      "${MAVEN}/com/fasterxml/jackson/core/jackson-core/${JACKSON_VERSION}/jackson-core-${JACKSON_VERSION}.jar"; \
    curl -fSL -o jackson-databind.jar \
      "${MAVEN}/com/fasterxml/jackson/core/jackson-databind/${JACKSON_VERSION}/jackson-databind-${JACKSON_VERSION}.jar"; \
    curl -fSL -o jackson-annotations.jar \
      "${MAVEN}/com/fasterxml/jackson/core/jackson-annotations/${JACKSON_VERSION}/jackson-annotations-${JACKSON_VERSION}.jar"; \
    curl -fSL -o flink-shaded-hadoop-2-uber.jar \
      "${MAVEN}/org/apache/flink/flink-shaded-hadoop-2-uber/${HADOOP_UBER_VERSION}/flink-shaded-hadoop-2-uber-${HADOOP_UBER_VERSION}.jar"

# Flink CDC Pipeline framework: extract the binary distribution (which contains
# the dist JAR and flink-cdc.sh) and download the pipeline connector JARs.
# The tarball and all connector artifacts use the combined version
# ${FLINK_CDC_VERSION}-${FLINK_MINOR} (e.g. 3.6.0-2.2).
#
# Key deployment rule for standalone Flink cluster (avoids classloader split):
#   1. flink-cdc-dist goes to /opt/flink/lib/ (CDC runtime on cluster classpath)
#   2. Pipeline connector JARs go to BOTH /opt/flink-cdc/lib/ (submitter classpath
#      used by flink-cdc.sh) AND /opt/flink/lib/ (cluster app classloader).
#
# Having the connector JARs in /opt/flink/lib/ combined with
# classloader.resolve-order=parent-first (set in docker-compose FLINK_PROPERTIES)
# ensures all CDC and connector classes are loaded from the app classloader on
# both JobManager and TaskManager. Without this, Flink's ChildFirstClassLoader
# would load the connector user-JARs (uploaded by flink-cdc.sh) in a separate
# classloader from flink-sql-connector-mysql-cdc (in /opt/flink/lib/), causing
# IllegalAccessError when MySqlDataSource (ChildFirst) tries to access
# MySqlSource$RecordEmitterSupplier (app). Parent-first resolves all CDC classes
# from the app classloader only, eliminating the split.
RUN set -eux; \
    mkdir -p /opt/flink-cdc; \
    curl -fSL \
      "https://downloads.apache.org/flink/flink-cdc-${FLINK_CDC_VERSION}/flink-cdc-${FLINK_CDC_VERSION}-${FLINK_MINOR}-bin.tar.gz" \
      | tar -xz --strip-components=1 -C /opt/flink-cdc; \
    chmod +x /opt/flink-cdc/bin/flink-cdc.sh; \
    cd /opt/flink-cdc/lib; \
    curl -fSL -o "flink-cdc-pipeline-connector-mysql-${FLINK_CDC_VERSION}-${FLINK_MINOR}.jar" \
      "${MAVEN}/org/apache/flink/flink-cdc-pipeline-connector-mysql/${FLINK_CDC_VERSION}-${FLINK_MINOR}/flink-cdc-pipeline-connector-mysql-${FLINK_CDC_VERSION}-${FLINK_MINOR}.jar"; \
    curl -fSL -o "flink-cdc-pipeline-connector-iceberg-${FLINK_CDC_VERSION}-${FLINK_MINOR}.jar" \
      "${MAVEN}/org/apache/flink/flink-cdc-pipeline-connector-iceberg/${FLINK_CDC_VERSION}-${FLINK_MINOR}/flink-cdc-pipeline-connector-iceberg-${FLINK_CDC_VERSION}-${FLINK_MINOR}.jar"; \
    cp "/opt/flink-cdc/lib/flink-cdc-dist-${FLINK_CDC_VERSION}-${FLINK_MINOR}.jar" /opt/flink/lib/; \
    cp "/opt/flink-cdc/lib/flink-cdc-pipeline-connector-mysql-${FLINK_CDC_VERSION}-${FLINK_MINOR}.jar" /opt/flink/lib/; \
    cp "/opt/flink-cdc/lib/flink-cdc-pipeline-connector-iceberg-${FLINK_CDC_VERSION}-${FLINK_MINOR}.jar" /opt/flink/lib/

# CDC pipeline definition and submission script.
COPY pipeline/ /opt/pipeline/
COPY scripts/submit-cdc-pipeline.sh /opt/submit-cdc-pipeline.sh
RUN chmod +x /opt/submit-cdc-pipeline.sh
