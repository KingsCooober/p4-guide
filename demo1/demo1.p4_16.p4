#include <core.p4>
#include <v1model.p4>

struct fwd_metadata_t {
    bit<32> l2ptr;
    bit<24> out_bd;
}

header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

header ipv4_t {
    bit<4>  version;
    bit<4>  ihl;
    bit<8>  diffserv;
    bit<16> totalLen;
    bit<16> identification;
    bit<3>  flags;
    bit<13> fragOffset;
    bit<8>  ttl;
    bit<8>  protocol;
    bit<16> hdrChecksum;
    bit<32> srcAddr;
    bit<32> dstAddr;
}

struct metadata {
    fwd_metadata_t fwd_metadata;
}

struct headers {
    ethernet_t ethernet;
    ipv4_t     ipv4;
}

// Why bother creating an action that just does one primitive action?
// That is, why not just use 'mark_to_drop' as one of the possible
// actions when defining a table?  Because the P4_16 compiler does not
// allow primitve actions to be used directly as actions of tables.
// You must use 'compound actions', i.e. ones explicitly defined with
// the 'action' keyword like below.

action my_drop() {
    mark_to_drop();
}

parser ParserImpl(packet_in packet,
                  out headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata)
{
    const bit<16> ETHERTYPE_IPV4 = 16w0x0800;

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            ETHERTYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }
    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }
    state start {
        transition parse_ethernet;
    }
}

control ingress(inout headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {
    action set_l2ptr(bit<32> l2ptr) {
        meta.fwd_metadata.l2ptr = l2ptr;
    }
    action set_bd_dmac_intf(bit<24> bd, bit<48> dmac, bit<9> intf) {
        meta.fwd_metadata.out_bd = bd;
        hdr.ethernet.dstAddr = dmac;
        standard_metadata.egress_spec = intf;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }
    table ipv4_da_lpm {
        actions = {
            set_l2ptr;
            my_drop;
        }
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        default_action = my_drop;
    }
    table mac_da {
        actions = {
            set_bd_dmac_intf;
            my_drop;
        }
        key = {
            meta.fwd_metadata.l2ptr: exact;
        }
        default_action = my_drop;
    }
    apply {
        ipv4_da_lpm.apply();
        mac_da.apply();
    }
}

control egress(inout headers hdr,
               inout metadata meta,
               inout standard_metadata_t standard_metadata)
{
    action rewrite_mac(bit<48> smac) {
        hdr.ethernet.srcAddr = smac;
    }
    table send_frame {
        actions = {
            rewrite_mac;
            my_drop;
        }
        key = {
            meta.fwd_metadata.out_bd: exact;
        }
        default_action = my_drop;
    }
    apply {
        send_frame.apply();
    }
}

control DeparserImpl(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
    }
}

control verifyChecksum(in headers hdr, inout metadata meta) {
    Checksum16() ipv4_checksum;
    apply {
        if ((hdr.ipv4.ihl == 4w5) &&
            (hdr.ipv4.hdrChecksum ==
             ipv4_checksum.get({ hdr.ipv4.version,
                         hdr.ipv4.ihl,
                         hdr.ipv4.diffserv,
                         hdr.ipv4.totalLen,
                         hdr.ipv4.identification,
                         hdr.ipv4.flags,
                         hdr.ipv4.fragOffset,
                         hdr.ipv4.ttl,
                         hdr.ipv4.protocol,
                         hdr.ipv4.srcAddr,
                         hdr.ipv4.dstAddr })))
        {
            mark_to_drop();
        }
    }
}

control computeChecksum(inout headers hdr, inout metadata meta) {
    Checksum16() ipv4_checksum;
    apply {
        if (hdr.ipv4.ihl == 4w5) {
            hdr.ipv4.hdrChecksum =
                ipv4_checksum.get({ hdr.ipv4.version,
                            hdr.ipv4.ihl,
                            hdr.ipv4.diffserv,
                            hdr.ipv4.totalLen,
                            hdr.ipv4.identification,
                            hdr.ipv4.flags,
                            hdr.ipv4.fragOffset,
                            hdr.ipv4.ttl,
                            hdr.ipv4.protocol,
                            hdr.ipv4.srcAddr,
                            hdr.ipv4.dstAddr });
        }
    }
}

V1Switch(ParserImpl(),
         verifyChecksum(),
         ingress(),
         egress(),
         computeChecksum(),
         DeparserImpl()) main;