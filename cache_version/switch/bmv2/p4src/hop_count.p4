/*************************************************************************
    > File Name: hop_count.c
    > Author: 
    > Mail: 
    > Created Time: Fri 11 May 2018 9:12:19 AM CST
************************************************************************/

#include "includes/headers.p4"
#include "includes/parser.p4"

#define HOP_COUNT_SIZE 8
#define HC_BITMAP_SIZE 32
#define HC_COMPUTE_TABLE_SIZE 8
#define HC_COMPUTE_TWICE_TABLE_SIZE 3
#define TCP_SESSION_MAP_BITS 8
#define TCP_SESSION_MAP_SIZE 256 // 2^8
#define TCP_SESSION_STATE_SIZE 1
#define IP_TO_HC_INDEX_BITS 23
#define IP_TO_HC_TABLE_SIZE 8388608 // 2^23
#define SAMPLE_VALUE_BITS 3
#define PACKET_TAG_BITS 1
#define HIT_BITS 8
#define CONTROLLER_PORT 3 // Maybe this parameter can be stored in a register 
#define PACKET_TRUNCATE_LENGTH 34
#define CLONE_SPEC_VALUE 250
#define CONTROLLER_IP_ADDRESS 3232238335 //192.168.10.255
#define CONTROLLER_MAC_ADDRESS 0x000600000010

header_type meta_t {
    fields {
        packet_hop_count : HOP_COUNT_SIZE; // Hop Count of this packet
        ip2hc_hop_count : HOP_COUNT_SIZE; // Hop Count in ip2hc table
        tcp_session_map_index : TCP_SESSION_MAP_BITS;
        tcp_session_state : TCP_SESSION_STATE_SIZE; // 1:received SYN-ACK 0: exist or none
        tcp_session_seq : 32; // sequince number of SYN-ACK packet
        ip_to_hc_index : IP_TO_HC_INDEX_BITS;
        sample_value : SAMPLE_VALUE_BITS; // Used for sample packets
        hcf_state : 1; // 0: Learning 1: Filtering
        packet_tag : PACKET_TAG_BITS; // 0: Normal 1: Abnormal
        is_inspected : 1; // 0: Not Inspected 1: Inspected
        ip2hc_table_hit : 1; // 0: Not Hit 1 : Hit
        reverse_ip_to_hc_table_hit : 1; // 0: Not Hit 1 : Hit
    }
}

metadata meta_t meta;

// The state of the switch, maintained by CPU(control.py)
register current_state {
    width : 1;
    instance_count : 1;
}

// The number(sampled) of abnormal packet per period
counter abnormal_counter {
    type : packets;
    instance_count : 1;
}

counter miss_counter {
    type : packets;
    instance_count : 1;
}

action check_hcf(is_inspected) {
    register_read(meta.hcf_state, current_state, 0);
    modify_field(meta.is_inspected, is_inspected);
}

// Used to get state(0:learning 1:filtering) of switch
// and judge whether the packet should be inspect by HCF
table hcf_check_table {
    reads {
        standard_metadata.ingress_port : exact;
    }
    actions { check_hcf; }
}

action _drop() {
    drop();
}

action tag_normal() {
    modify_field(meta.packet_tag, 0);
}

// Tag the packet as normal
table packet_normal_table {
    actions { tag_normal; }
}

action tag_abnormal() {
    modify_field(meta.packet_tag, 1);
}

// Tag the packet as abnormal
table packet_abnormal_table {
    actions { tag_abnormal; }
}

action compute_hc(initial_ttl) {
    subtract(meta.packet_hop_count, initial_ttl, ipv4.ttl);
}

// According to final TTL, select initial TTL and compute hop count
table hc_compute_table {
    reads {
        ipv4.ttl : range;
    }
    actions {
        compute_hc;
    }
    size: HC_COMPUTE_TABLE_SIZE;
}

// Another for different pipeline
table hc_compute_table_copy {
    reads {
        ipv4.ttl : range;
    }
    actions {
        compute_hc;
    }
    size: HC_COMPUTE_TABLE_SIZE;
}

action inspect_hc() {
    register_read(meta.ip2hc_hop_count, hop_count, meta.ip_to_hc_index);
}

// Get the origin hop count of this source IP
table hc_inspect_table {
    actions { inspect_hc; }
}

// Save the hop count value of each source ip address
register hop_count {
    width : HOP_COUNT_SIZE;
    instance_count : IP_TO_HC_TABLE_SIZE;
}

// Save the hit count value of each entry in ip2hc table
counter hit_count {
    type : packets;
    instance_count : IP_TO_HC_TABLE_SIZE;
}

action table_miss() {
    count(miss_counter, 0);
    modify_field(meta.ip2hc_table_hit, 0);
}

action table_hit(index) {
    modify_field(meta.ip_to_hc_index, index);
    count(hit_count, index);
    modify_field(meta.ip2hc_table_hit, 1);
}

// The ip2hc table, if the current packet hits the ip2hc table, action 
// table_hit is executed, otherwise action table_miss is executed
table ip_to_hc_table {
    reads {
        ipv4.srcAddr : exact;
    }
    actions {
        table_miss;
        table_hit;
    }
    size : IP_TO_HC_TABLE_SIZE;
}

action reverse_table_hit() {
    modify_field(meta.reverse_ip_to_hc_table_hit, 1);
}

action reverse_table_miss() {
    modify_field(meta.reverse_ip_to_hc_table_hit, 0);
}

table reverse_ip_to_hc_table {
    reads {
        ipv4.dstAddr : exact;
    }
    actions {
        reverse_table_miss;
        reverse_table_hit;
    }
}

action learning_abnormal() {
    count(abnormal_counter, 0);
    tag_normal();
}

action filtering_abnormal() {
    count(abnormal_counter, 0);
    tag_abnormal();
}

// If the packet is judged as abnormal because its suspected hop-count,
// handle it according to the switch state and whether the packet is sampled.
// For learning state: if the packet is sampled, just update abnormal_counter 
// and tag it as normal(don't drop it); if the packet is not sampled, it won't 
// go through this table because switch don't check its hop count.
// For filtering state, every abnormal packets should be dropped but update 
// abnormal_counter specially for these sampled.
table hc_abnormal_table {
    reads {
        meta.hcf_state : exact;
    }
    actions {
        learning_abnormal;
        filtering_abnormal;
    }
}

field_list l3_hash_fields {
    ipv4.srcAddr;
    ipv4.dstAddr;
    ipv4.protocol;
    tcp.srcPort;
    tcp.dstPort;
}

field_list_calculation tcp_session_map_hash {
    input {
        l3_hash_fields;
    }
    algorithm : crc16;
    output_width : TCP_SESSION_MAP_BITS;
}

field_list reverse_l3_hash_fields {
    ipv4.dstAddr;
    ipv4.srcAddr;
    ipv4.protocol;
    tcp.dstPort;
    tcp.srcPort;
}

field_list_calculation reverse_tcp_session_map_hash {
    input {
        reverse_l3_hash_fields;
    }
    algorithm : crc16;
    output_width : TCP_SESSION_MAP_BITS;
}

action lookup_session_map() {
    modify_field_with_hash_based_offset(
        meta.tcp_session_map_index, 0,
        tcp_session_map_hash, TCP_SESSION_MAP_SIZE
    );
    register_read(
        meta.tcp_session_state, session_state, 
        meta.tcp_session_map_index
    );
    register_read(
        meta.tcp_session_seq, session_seq,
        meta.tcp_session_map_index
    );
}

action lookup_reverse_session_map() {
    modify_field_with_hash_based_offset(
        meta.tcp_session_map_index, 0,
        reverse_tcp_session_map_hash, TCP_SESSION_MAP_SIZE
    );
    register_read(
        meta.tcp_session_state, session_state, 
        meta.tcp_session_map_index
    );
    register_read(
        meta.tcp_session_seq, session_seq,
        meta.tcp_session_map_index
    );
}

// Get packets' tcp session information. Notice: dual direction packets in one 
// flow should belong to same tcp session and use same hash value
table session_check_table {
    reads {
        standard_metadata.ingress_port : exact;
    }
    actions {
        lookup_session_map;
        lookup_reverse_session_map;
    }
}

// Store sesscon state for concurrent tcp connections
register session_state {
    width : TCP_SESSION_STATE_SIZE;
    instance_count : TCP_SESSION_MAP_SIZE;
} 

// Store sesscon sequince number(SYN-ACK's) for concurrent tcp connections
register session_seq {
    width : 32;
    instance_count : TCP_SESSION_MAP_SIZE;
} 

action init_session() {
    register_write(session_state, meta.tcp_session_map_index, 1);
    register_write(session_seq, meta.tcp_session_map_index, tcp.seqNo);
}

// Someone is attempting to establish a connection from server
table session_init_table {
    actions {
        init_session;
    }
}

action complete_session() {
    register_write(session_state, meta.tcp_session_map_index, 0);
    register_write(hop_count, meta.ip_to_hc_index, meta.packet_hop_count);
    tag_normal();
}

// Establish the connection, and update IP2HC
table session_complete_table {
    reads {
        tcp.ack : exact;
    }
    actions {
        tag_abnormal;
        complete_session;
    }
}

action forward_l2(egress_port) {
    modify_field(standard_metadata.egress_spec, egress_port);
}

// Forward table, now it just support layer 2
table l2_forward_table {
    reads {
        meta.packet_tag : exact;
        standard_metadata.ingress_port : exact;
    }
    actions {
        _drop;
        forward_l2;
    }
}

// Metadata used in clone function
field_list meta_data_for_clone {
    standard_metadata;
}

action packet_clone() {
    //modify_field(standard_metadata.egress_spec, CONTROLLER_PORT);
    clone_ingress_pkt_to_egress(CLONE_SPEC_VALUE, meta_data_for_clone);
}

// When a packet is missed, clone it and send it to controller
table miss_packet_clone_table {
    actions {
        packet_clone;
    }
}

// For a different pipeline
table miss_packet_clone_table_copy {
    actions {
        packet_clone;
    }
}

action modify_field_and_truncate() {
    modify_field(ethernet.dstAddr, CONTROLLER_MAC_ADDRESS);
    modify_field(ipv4.dstAddr, CONTROLLER_IP_ADDRESS);
    truncate(PACKET_TRUNCATE_LENGTH);
}

// Only the packets' header are send to controller 
table modify_field_and_truncate_table {
    actions {
        modify_field_and_truncate;
    }
}

table packet_miss_table {
    reads {
        meta.hcf_state : exact;
    }
    actions {
        tag_normal;
        tag_abnormal;
    }
}

action session_complete_update() {
    //modify_field(ipv4.dstAddr, CONTROLLER_IP_ADDRESS);
    //modify_field(standard_metadata.egress_spec, CONTROLLER_PORT);
    clone_ingress_pkt_to_egress(CLONE_SPEC_VALUE, meta_data_for_clone);
}

table session_complete_update_table {
    actions {
        session_complete_update;
    }
}

control ingress {
    if (standard_metadata.ingress_port == CONTROLLER_PORT) {
        // Packets from controller must be normal packets
        apply(packet_normal_table);
    }
    else {
        // Get basic infomation of switch
        apply(hcf_check_table);
        if (tcp.syn == 1 and tcp.ack == 1) {
            apply(reverse_ip_to_hc_table);
            if (meta.reverse_ip_to_hc_table_hit == 0)
                apply(miss_packet_clone_table);
            else   
                apply(session_init_table);
            apply(packet_normal_table);
        }
        else {
            // Judge whether the current hits ip2hc table
            apply(ip_to_hc_table);
            if (meta.ip2hc_table_hit == 1) {
                // Get session state
                apply(session_check_table);
                if (meta.tcp_session_state == 1) {
                    // The connection is wainting to be established
                    if (tcp.ackNo == meta.tcp_session_seq + 1) {
                        // Legal connection, so real hop count to be stored
                        apply(hc_compute_table_copy);
                        apply(session_complete_table);
                        apply(session_complete_update_table);
                    }
                    else {
                        // Illegal connection attempt
                        apply(packet_abnormal_table);
                    }
                }
                else if (meta.tcp_session_state == 0) {
                    if (meta.is_inspected == 1) {
                        // Compute packet's hop count and refer to its origin hop count
                        apply(hc_compute_table);
                        apply(hc_inspect_table);
                        if (meta.packet_hop_count != meta.ip2hc_hop_count) {
                            // It's abnormal
                            apply(hc_abnormal_table);
                        }
                        else {
                            // It is normal
                            apply(packet_normal_table);
                        }
                    }
                    else {
                        apply(packet_normal_table);
                    }
                }
            }
            else if (meta.ip2hc_table_hit == 0)
            {
                apply(miss_packet_clone_table_copy);
                apply(packet_miss_table);
            }
        }
    }
    // Drop abnormal packets and forward normal packets in layer two
    apply(l2_forward_table);
}

control egress {
    if (standard_metadata.egress_port == CONTROLLER_PORT
        and (meta.hcf_state == 0 or ipv4.dstAddr == CONTROLLER_IP_ADDRESS)) {
        apply(modify_field_and_truncate_table);
    }
}
