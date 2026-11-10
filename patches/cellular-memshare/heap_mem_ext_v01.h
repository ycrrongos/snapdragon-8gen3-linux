/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Qualcomm Dynamic Heap Memory Sharing QMI protocol.
 *
 * The wire definitions originate from the Android common-kernel memshare
 * service.  Keep the message IDs and TLV layout compatible with service
 * 0x34, version 1, instance 1.
 */

#ifndef _CERRO_HEAP_MEM_EXT_V01_H
#define _CERRO_HEAP_MEM_EXT_V01_H

#include <linux/soc/qcom/qmi.h>

#define MEM_ALLOC_REQ_MAX_MSG_LEN_V01	255
#define MEM_FREE_REQ_MAX_MSG_LEN_V01	255
#define MEM_QUERY_MAX_MSG_LEN_V01	255
#define MAX_ARR_CNT_V01			64

struct dhms_mem_alloc_addr_info_type_v01 {
	u64 phy_addr;
	u32 num_bytes;
};

enum dhms_mem_proc_id_v01 {
	DHMS_MEM_PROC_ID_MIN_ENUM_VAL_V01 = -2147483647,
	DHMS_MEM_PROC_MPSS_V01 = 0,
	DHMS_MEM_PROC_ADSP_V01 = 1,
	DHMS_MEM_PROC_WCNSS_V01 = 2,
	DHMS_MEM_PROC_ID_MAX_ENUM_VAL_V01 = 2147483647,
};

enum dhms_mem_client_id_v01 {
	DHMS_MEM_CLIENT_ID_MIN_ENUM_VAL_V01 = -2147483647,
	DHMS_MEM_CLIENT_GPS_V01 = 0,
	DHMS_MEM_CLIENT_INVALID = 1000,
	DHMS_MEM_CLIENT_ID_MAX_ENUM_VAL_V01 = 2147483647,
};

enum dhms_mem_block_align_enum_v01 {
	DHMS_MEM_BLOCK_ALIGN_ENUM_MIN_ENUM_VAL_V01 = -2147483647,
	DHMS_MEM_BLOCK_ALIGN_2_V01 = 0,
	DHMS_MEM_BLOCK_ALIGN_4_V01 = 1,
	DHMS_MEM_BLOCK_ALIGN_8_V01 = 2,
	DHMS_MEM_BLOCK_ALIGN_16_V01 = 3,
	DHMS_MEM_BLOCK_ALIGN_32_V01 = 4,
	DHMS_MEM_BLOCK_ALIGN_64_V01 = 5,
	DHMS_MEM_BLOCK_ALIGN_128_V01 = 6,
	DHMS_MEM_BLOCK_ALIGN_256_V01 = 7,
	DHMS_MEM_BLOCK_ALIGN_512_V01 = 8,
	DHMS_MEM_BLOCK_ALIGN_1K_V01 = 9,
	DHMS_MEM_BLOCK_ALIGN_2K_V01 = 10,
	DHMS_MEM_BLOCK_ALIGN_4K_V01 = 11,
	DHMS_MEM_BLOCK_ALIGN_ENUM_MAX_ENUM_VAL_V01 = 2147483647,
};

struct mem_alloc_generic_req_msg_v01 {
	u32 num_bytes;
	enum dhms_mem_client_id_v01 client_id;
	enum dhms_mem_proc_id_v01 proc_id;
	u32 sequence_id;
	u8 alloc_contiguous_valid;
	u8 alloc_contiguous;
	u8 block_alignment_valid;
	enum dhms_mem_block_align_enum_v01 block_alignment;
};

struct mem_alloc_generic_resp_msg_v01 {
	struct qmi_response_type_v01 resp;
	u8 sequence_id_valid;
	u32 sequence_id;
	u8 dhms_mem_alloc_addr_info_valid;
	u32 dhms_mem_alloc_addr_info_len;
	struct dhms_mem_alloc_addr_info_type_v01
		dhms_mem_alloc_addr_info[MAX_ARR_CNT_V01];
};

struct mem_free_generic_req_msg_v01 {
	u32 dhms_mem_alloc_addr_info_len;
	struct dhms_mem_alloc_addr_info_type_v01
		dhms_mem_alloc_addr_info[MAX_ARR_CNT_V01];
	u8 client_id_valid;
	enum dhms_mem_client_id_v01 client_id;
	u8 proc_id_valid;
	enum dhms_mem_proc_id_v01 proc_id;
};

struct mem_free_generic_resp_msg_v01 {
	struct qmi_response_type_v01 resp;
};

struct mem_query_size_req_msg_v01 {
	enum dhms_mem_client_id_v01 client_id;
	u8 proc_id_valid;
	enum dhms_mem_proc_id_v01 proc_id;
};

struct mem_query_size_rsp_msg_v01 {
	struct qmi_response_type_v01 resp;
	u8 size_valid;
	u32 size;
};

extern const struct qmi_elem_info mem_alloc_generic_req_msg_data_v01_ei[];
extern const struct qmi_elem_info mem_alloc_generic_resp_msg_data_v01_ei[];
extern const struct qmi_elem_info mem_free_generic_req_msg_data_v01_ei[];
extern const struct qmi_elem_info mem_free_generic_resp_msg_data_v01_ei[];
extern const struct qmi_elem_info mem_query_size_req_msg_data_v01_ei[];
extern const struct qmi_elem_info mem_query_size_resp_msg_data_v01_ei[];

#define MEM_ALLOC_GENERIC_REQ_MSG_V01	0x0022
#define MEM_ALLOC_GENERIC_RESP_MSG_V01	0x0022
#define MEM_FREE_GENERIC_REQ_MSG_V01	0x0023
#define MEM_FREE_GENERIC_RESP_MSG_V01	0x0023
#define MEM_QUERY_SIZE_REQ_MSG_V01	0x0024
#define MEM_QUERY_SIZE_RESP_MSG_V01	0x0024

#endif

