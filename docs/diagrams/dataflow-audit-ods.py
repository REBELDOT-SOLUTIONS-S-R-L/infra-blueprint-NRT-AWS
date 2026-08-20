"""
Data flow — Use Case 3: Controlled ingestion & warm ODS/audit layer.

This is the foundational flow every other use case sits on top of, and it's the one that
most directly answers the problem stated in ARCHITECTURE.md: ~2,000 apps currently read
uncontrolled replicas off on-prem Oracle Exadata with no shared schema/lineage, and a
7-day-retention on-prem ODS is expensive. This diagram shows the same transaction/event
stream governed by the Glue Schema Registry and landed in S3/Iceberg as a queryable,
configurable-retention replacement for that ODS — independent of which downstream use case
(NBA/NBO, fraud, or another) consumes the stream.

Regenerate: python3 dataflow-audit-ods.py
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.analytics import (
    ManagedStreamingForKafka,
    GlueDataCatalog,
    Athena,
)
from diagrams.aws.compute import Lambda
from diagrams.aws.storage import S3
from diagrams.aws.general import Users
from diagrams.onprem.database import Oracle

graph_attr = {"fontsize": "20", "bgcolor": "white", "pad": "0.8", "splines": "spline", "nodesep": "0.6"}

with Diagram(
    "Use Case 3 — Controlled Ingestion & Warm ODS/Audit Layer",
    filename="dataflow-audit-ods",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
):
    source = Oracle("Oracle Exadata\n(on-prem,\nde facto DWH today)")

    with Cluster("integration account"):
        connect = ManagedStreamingForKafka("MSK Connect\n(~2,000 adapter\nconnectors)")
        topics = ManagedStreamingForKafka("MSK topics\n(1 per event type)")
        registry = GlueDataCatalog("Glue Schema Registry\n(versioned schemas,\nreplaces 'no shared\nschema' pain point)")
        connect >> Edge(label="produce") >> topics
        topics - Edge(style="dashed", label="schema\ncompatibility\ncheck") - registry

    with Cluster("nrt-processing account"):
        transform = Lambda("Lambda:\nvalidate, dedup,\nroute")

    with Cluster("data account"):
        lakehouse = S3("S3 + Iceberg\n(warm ODS, TTL is a\nconfigurable variable —\nADR-0007)")
        catalog = GlueDataCatalog("Glue Data Catalog\n(Iceberg metastore)")
        athena = Athena("Athena\n(ad hoc query)")
        lakehouse - catalog
        catalog - athena

    consumers = Users("~2,000 internal apps\n(replacing uncontrolled\nreplica sprawl)")

    source >> Edge(label="1. GoldenGate CDC\nover Direct Connect/VPN") >> connect
    topics >> Edge(label="2. consume") >> transform
    transform >> Edge(label="3. write") >> lakehouse
    topics >> Edge(label="2b. direct consume\n(schema-governed)", style="dashed") >> consumers
    athena >> Edge(label="4. query\n(audit, analytics)") >> consumers
