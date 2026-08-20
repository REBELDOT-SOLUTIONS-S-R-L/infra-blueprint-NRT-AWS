"""
NRT Platform — network / account architecture diagram.

Generated with the mingrammer/diagrams library (real AWS Architecture Icons) per the
project's diagram-format decision recorded for this README pass. Regenerate with:

    pip install diagrams --break-system-packages   # requires graphviz (`dot`) on PATH
    python3 network-architecture.py

Reflects the 4-boundary hub-and-spoke topology in
docs/architecture-decisions/0001-multi-account-hub-spoke-network-topology.md,
0002 (MSK placement), 0003 (GoldenGate on-prem connectivity), and 0004 (CIDR policy).

No real account IDs, ARNs, CIDR ranges, or hostnames — boundary names match the
`boundary_name` values actually used in environments/*/main.tf. Per ARCHITECTURE.md's compliance
notes, this is a logical diagram only.
"""

from diagrams import Diagram, Cluster, Edge
from diagrams.aws.network import TransitGateway, DirectConnect, SiteToSiteVpn
from diagrams.aws.analytics import (
    ManagedStreamingForKafka,
    KinesisDataAnalytics,
    GlueDataCatalog,
    Athena,
)
from diagrams.aws.compute import Lambda
from diagrams.aws.database import ElastiCache
from diagrams.aws.storage import S3
from diagrams.aws.integration import SNS
from diagrams.aws.engagement import SES
from diagrams.onprem.database import Oracle
from diagrams.aws.general import Users, MobileClient

graph_attr = {
    "fontsize": "20",
    "bgcolor": "white",
    "pad": "0.5",
    "splines": "spline",
}

with Diagram(
    "NRT Platform — 4-Boundary Hub-and-Spoke Architecture",
    filename="network-architecture",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
):
    with Cluster("On-Premises Data Center"):
        onprem_source = Oracle("Oracle Exadata\n+ GoldenGate CDC")

    with Cluster("network account (hub)\nboundary: network-shared"):
        dx = DirectConnect("Direct Connect")
        vpn = SiteToSiteVpn("Site-to-Site VPN\n(backup path)")
        tgw = TransitGateway("Transit Gateway\n(full-mesh spoke routing)")
        dx >> Edge(label="CDC feed") >> tgw
        vpn >> tgw

    with Cluster("integration account\nboundary: integration"):
        msk = ManagedStreamingForKafka("Amazon MSK\n(partitioned topics\nper event type)")
        msk_connect = ManagedStreamingForKafka("MSK Connect\n(~2,000 adapter\nconnectors)")
        schema_registry = GlueDataCatalog("Glue Schema Registry\n(schema versioning)")
        msk_connect >> Edge(label="produce/consume,\nTLS + IAM auth") >> msk
        msk - Edge(style="dashed", label="schema\nenforcement") - schema_registry

    with Cluster("nrt-processing account\nboundary: nrt-processing"):
        flink = KinesisDataAnalytics("Managed Service\nfor Apache Flink\n(enrichment, rules,\nwindowed aggregation)")
        lambda_fn = Lambda("Lambda\n(validation, dedup,\nrouting)")
        redis = ElastiCache("ElastiCache (Redis)\nhot session/user state")
        sns = SNS("SNS\n(push / in-app)")
        ses = SES("SES\n(email)")

        flink >> redis
        flink >> lambda_fn
        flink >> sns
        flink >> ses

    with Cluster("data account\nboundary: data"):
        lakehouse = S3("S3 + Iceberg\nwarm ODS / audit\n(configurable TTL)")
        catalog = GlueDataCatalog("Glue Data Catalog\n(Iceberg metastore)")
        athena = Athena("Athena\n(query workgroups)")
        lakehouse - catalog
        catalog - athena

    with Cluster("~2,000 internal consuming apps\n(existing, org-wide)"):
        apps = Users("Internal app teams")

    with Cluster("Customers"):
        mobile = MobileClient("Mobile / online\nbanking app")

    onprem_source >> Edge(label="Direct Connect / VPN") >> dx
    tgw >> Edge(label="TGW attachment") >> msk
    tgw >> Edge(label="TGW attachment") >> flink
    tgw >> Edge(label="TGW attachment") >> lakehouse
    msk >> Edge(label="cross-account,\nIAM auth over TGW") >> flink
    flink >> Edge(label="enriched events") >> lakehouse
    apps >> Edge(label="produce/consume\nvia MSK Connect") >> msk_connect
    sns >> mobile
    ses >> mobile
