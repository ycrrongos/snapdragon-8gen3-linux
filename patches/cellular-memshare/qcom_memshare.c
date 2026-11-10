// SPDX-License-Identifier: GPL-2.0-only
/*
 * Qualcomm Dynamic Heap Memory Sharing service, mainline API port.
 *
 * This intentionally keeps the QMI protocol and allocation semantics needed
 * by Cerro MPSS while omitting downstream subsystem-restart ramdump glue.
 */

#include <linux/bitops.h>
#include <linux/dma-mapping.h>
#include <linux/firmware/qcom/qcom_scm.h>
#include <linux/iommu.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <linux/of_reserved_mem.h>
#include <linux/platform_device.h>
#include <linux/sizes.h>
#include <linux/soc/qcom/qmi.h>

#include <dt-bindings/firmware/qcom,scm.h>

#include "heap_mem_ext_v01.h"

#define MEMSHARE_SERVICE_ID	0x34
#define MEMSHARE_SERVICE_VERSION 1
#define MEMSHARE_SERVICE_INSTANCE 1
#define MEMSHARE_MAX_CLIENTS	10
#define MEMSHARE_GUARD_BYTES	SZ_4K

struct qcom_memshare;

struct qcom_memshare_client {
	struct qcom_memshare *memshare;
	struct device *dev;
	u32 client_id;
	u32 proc_id;
	u32 configured_size;
	u32 sequence_id;
	bool allocate_at_boot;
	bool allocate_on_request;
	bool guard_band;
	bool shared;
	bool reserved_mem;
	bool allotted;
	bool scm_assigned;
	size_t alloc_size;
	void *dma_cookie;
	dma_addr_t dma_addr;
	u64 permissions;
};

struct qcom_memshare {
	struct device *dev;
	/* Serializes the client table and all allocation ownership changes. */
	struct mutex lock;
	struct qmi_handle qmi;
	bool qmi_ready;
	unsigned int num_clients;
	struct qcom_memshare_client *clients[MEMSHARE_MAX_CLIENTS];
};

static struct qcom_memshare_client *
qcom_memshare_find_client(struct qcom_memshare *memshare, u32 client_id,
			  u32 proc_id)
{
	unsigned int i;

	for (i = 0; i < memshare->num_clients; i++) {
		struct qcom_memshare_client *client = memshare->clients[i];

		if (client->client_id == client_id && client->proc_id == proc_id)
			return client;
	}

	return NULL;
}

static int qcom_memshare_assign(struct qcom_memshare_client *client)
{
	struct qcom_scm_vmperm perms[2];
	unsigned int count = 0;
	int ret;

	client->permissions = BIT(QCOM_SCM_VMID_HLOS);

	if (client->shared) {
		perms[count].vmid = QCOM_SCM_VMID_HLOS;
		perms[count++].perm = QCOM_SCM_PERM_RW;
	}

	perms[count].vmid = QCOM_SCM_VMID_MSS_MSA;
	perms[count++].perm = QCOM_SCM_PERM_RW;

	ret = qcom_scm_assign_mem(client->dma_addr, client->alloc_size,
				  &client->permissions, perms, count);
	if (ret)
		return ret;

	client->scm_assigned = true;
	return 0;
}

static int qcom_memshare_reclaim(struct qcom_memshare_client *client)
{
	struct qcom_scm_vmperm perm = {
		.vmid = QCOM_SCM_VMID_HLOS,
		.perm = QCOM_SCM_PERM_RW,
	};
	int ret;

	if (!client->scm_assigned)
		return 0;

	ret = qcom_scm_assign_mem(client->dma_addr, client->alloc_size,
				  &client->permissions, &perm, 1);
	if (!ret)
		client->scm_assigned = false;

	return ret;
}

static int qcom_memshare_allocate(struct qcom_memshare_client *client,
				  u32 requested_size)
{
	size_t size;
	int ret;

	if (!requested_size || requested_size != client->configured_size)
		return -EINVAL;

	if (client->allotted)
		return client->alloc_size >= requested_size ? 0 : -EINVAL;

	if (device_iommu_mapped(client->dev)) {
		dev_err(client->dev,
			"IOMMU-backed DMA cannot be returned as a physical address\n");
		return -EOPNOTSUPP;
	}

	size = requested_size;
	if (client->guard_band)
		size += MEMSHARE_GUARD_BYTES;
	size = PAGE_ALIGN(size);

	client->dma_cookie = dma_alloc_attrs(client->dev, size,
					     &client->dma_addr,
					     GFP_KERNEL | __GFP_NOWARN,
					     DMA_ATTR_NO_KERNEL_MAPPING);
	if (!client->dma_cookie)
		return -ENOMEM;

	client->alloc_size = size;
	ret = qcom_memshare_assign(client);
	if (ret) {
		dma_free_attrs(client->dev, client->alloc_size,
			       client->dma_cookie, client->dma_addr,
			       DMA_ATTR_NO_KERNEL_MAPPING);
		client->dma_cookie = NULL;
		client->dma_addr = 0;
		client->alloc_size = 0;
		return ret;
	}

	client->allotted = true;
	return 0;
}

static void qcom_memshare_release(struct qcom_memshare_client *client)
{
	int ret;

	if (!client->allotted)
		return;

	ret = qcom_memshare_reclaim(client);
	if (ret) {
		dev_err(client->dev,
			"failed to reclaim MPSS memory ownership: %d\n", ret);
		return;
	}

	dma_free_attrs(client->dev, client->alloc_size, client->dma_cookie,
		       client->dma_addr, DMA_ATTR_NO_KERNEL_MAPPING);
	client->dma_cookie = NULL;
	client->dma_addr = 0;
	client->alloc_size = 0;
	client->allotted = false;
}

static void qcom_memshare_alloc_req(struct qmi_handle *qmi,
				    struct sockaddr_qrtr *sq,
				    struct qmi_txn *txn,
				    const void *decoded)
{
	const struct mem_alloc_generic_req_msg_v01 *req = decoded;
	struct qcom_memshare *memshare = container_of(qmi, struct qcom_memshare,
						      qmi);
	struct mem_alloc_generic_resp_msg_v01 *rsp;
	struct qcom_memshare_client *client;
	u16 error = QMI_ERR_NO_MEMORY_V01;
	int ret;

	rsp = kzalloc_obj(*rsp);
	if (!rsp)
		return;

	rsp->resp.result = QMI_RESULT_FAILURE_V01;
	rsp->resp.error = QMI_ERR_NO_MEMORY_V01;
	rsp->sequence_id_valid = 1;
	rsp->sequence_id = req->sequence_id;

	mutex_lock(&memshare->lock);
	client = qcom_memshare_find_client(memshare, req->client_id, req->proc_id);
	if (!client) {
		error = QMI_ERR_INVALID_ID_V01;
		goto unlock;
	}

	if (!client->allocate_on_request ||
	    req->num_bytes != client->configured_size) {
		error = QMI_ERR_INVALID_ID_V01;
		goto unlock;
	}

	ret = qcom_memshare_allocate(client, req->num_bytes);
	if (ret) {
		dev_err(client->dev,
			"allocation failed for client %u size %u: %d\n",
			client->client_id, req->num_bytes, ret);
		goto unlock;
	}

	client->sequence_id = req->sequence_id;
	rsp->dhms_mem_alloc_addr_info_valid = 1;
	rsp->dhms_mem_alloc_addr_info_len = 1;
	rsp->dhms_mem_alloc_addr_info[0].phy_addr = client->dma_addr;
	rsp->dhms_mem_alloc_addr_info[0].num_bytes = req->num_bytes;
	rsp->resp.result = QMI_RESULT_SUCCESS_V01;
	rsp->resp.error = QMI_ERR_NONE_V01;
	dev_info(client->dev,
		 "allocated client %u proc %u size %u for MPSS\n",
		 client->client_id, client->proc_id, req->num_bytes);

unlock:
	if (rsp->resp.result != QMI_RESULT_SUCCESS_V01)
		rsp->resp.error = error;
	mutex_unlock(&memshare->lock);

	ret = qmi_send_response(qmi, sq, txn, MEM_ALLOC_GENERIC_RESP_MSG_V01,
				MEM_ALLOC_REQ_MAX_MSG_LEN_V01,
				mem_alloc_generic_resp_msg_data_v01_ei, rsp);
	if (ret)
		dev_err(memshare->dev, "failed to send allocation response: %d\n",
			ret);

	kfree(rsp);
}

static void qcom_memshare_free_req(struct qmi_handle *qmi,
				   struct sockaddr_qrtr *sq,
				   struct qmi_txn *txn,
				   const void *decoded)
{
	const struct mem_free_generic_req_msg_v01 *req = decoded;
	struct qcom_memshare *memshare = container_of(qmi, struct qcom_memshare,
						      qmi);
	struct mem_free_generic_resp_msg_v01 rsp = {
		.resp.result = QMI_RESULT_FAILURE_V01,
		.resp.error = QMI_ERR_INVALID_ID_V01,
	};
	struct qcom_memshare_client *client;
	u32 proc_id = req->proc_id_valid ? req->proc_id : DHMS_MEM_PROC_MPSS_V01;
	int ret;

	mutex_lock(&memshare->lock);
	client = req->client_id_valid ?
		qcom_memshare_find_client(memshare, req->client_id, proc_id) : NULL;

	/*
	 * Downstream keeps allocate-on-request buffers across a free request and
	 * modem restart, then returns the same allocation.  Preserve that policy;
	 * module removal is the only point at which ownership is reclaimed.
	 */
	if (client && client->allocate_on_request) {
		rsp.resp.result = QMI_RESULT_SUCCESS_V01;
		rsp.resp.error = QMI_ERR_NONE_V01;
	}
	mutex_unlock(&memshare->lock);

	ret = qmi_send_response(qmi, sq, txn, MEM_FREE_GENERIC_RESP_MSG_V01,
				MEM_FREE_REQ_MAX_MSG_LEN_V01,
				mem_free_generic_resp_msg_data_v01_ei, &rsp);
	if (ret)
		dev_err(memshare->dev, "failed to send free response: %d\n", ret);
}

static void qcom_memshare_query_req(struct qmi_handle *qmi,
				    struct sockaddr_qrtr *sq,
				    struct qmi_txn *txn,
				    const void *decoded)
{
	const struct mem_query_size_req_msg_v01 *req = decoded;
	struct qcom_memshare *memshare = container_of(qmi, struct qcom_memshare,
						      qmi);
	struct mem_query_size_rsp_msg_v01 rsp = {
		.resp.result = QMI_RESULT_FAILURE_V01,
		.resp.error = QMI_ERR_INVALID_ID_V01,
	};
	struct qcom_memshare_client *client;
	u32 proc_id = req->proc_id_valid ? req->proc_id : DHMS_MEM_PROC_MPSS_V01;
	int ret;

	mutex_lock(&memshare->lock);
	client = qcom_memshare_find_client(memshare, req->client_id, proc_id);
	if (client) {
		rsp.resp.result = QMI_RESULT_SUCCESS_V01;
		rsp.resp.error = QMI_ERR_NONE_V01;
		rsp.size_valid = 1;
		rsp.size = client->configured_size;
		dev_info(client->dev, "query client %u proc %u size %u\n",
			 client->client_id, client->proc_id,
			 client->configured_size);
	}
	mutex_unlock(&memshare->lock);

	ret = qmi_send_response(qmi, sq, txn, MEM_QUERY_SIZE_RESP_MSG_V01,
				MEM_QUERY_MAX_MSG_LEN_V01,
				mem_query_size_resp_msg_data_v01_ei, &rsp);
	if (ret)
		dev_err(memshare->dev, "failed to send query response: %d\n", ret);
}

static const struct qmi_msg_handler qcom_memshare_handlers[] = {
	{
		.type = QMI_REQUEST,
		.msg_id = MEM_ALLOC_GENERIC_REQ_MSG_V01,
		.ei = mem_alloc_generic_req_msg_data_v01_ei,
		.decoded_size = sizeof(struct mem_alloc_generic_req_msg_v01),
		.fn = qcom_memshare_alloc_req,
	},
	{
		.type = QMI_REQUEST,
		.msg_id = MEM_FREE_GENERIC_REQ_MSG_V01,
		.ei = mem_free_generic_req_msg_data_v01_ei,
		.decoded_size = sizeof(struct mem_free_generic_req_msg_v01),
		.fn = qcom_memshare_free_req,
	},
	{
		.type = QMI_REQUEST,
		.msg_id = MEM_QUERY_SIZE_REQ_MSG_V01,
		.ei = mem_query_size_req_msg_data_v01_ei,
		.decoded_size = sizeof(struct mem_query_size_req_msg_v01),
		.fn = qcom_memshare_query_req,
	},
	{ },
};

static int qcom_memshare_child_probe(struct platform_device *pdev)
{
	struct qcom_memshare *memshare = dev_get_drvdata(pdev->dev.parent);
	struct qcom_memshare_client *client;
	const char *label;
	unsigned int i;
	int ret;

	if (!memshare)
		return -EPROBE_DEFER;

	client = devm_kzalloc(&pdev->dev, sizeof(*client), GFP_KERNEL);
	if (!client)
		return -ENOMEM;

	ret = of_property_read_u32(pdev->dev.of_node, "qcom,peripheral-size",
				   &client->configured_size);
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
				     "missing qcom,peripheral-size\n");

	ret = of_property_read_u32(pdev->dev.of_node, "qcom,client-id",
				   &client->client_id);
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "missing qcom,client-id\n");

	ret = of_property_read_string(pdev->dev.of_node, "label", &label);
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "missing peripheral label\n");

	if (!strcmp(label, "modem"))
		client->proc_id = DHMS_MEM_PROC_MPSS_V01;
	else if (!strcmp(label, "adsp"))
		client->proc_id = DHMS_MEM_PROC_ADSP_V01;
	else if (!strcmp(label, "wcnss"))
		client->proc_id = DHMS_MEM_PROC_WCNSS_V01;
	else
		return dev_err_probe(&pdev->dev, -EINVAL,
				     "unsupported peripheral label %s\n", label);

	client->allocate_at_boot = of_property_read_bool(pdev->dev.of_node,
							 "qcom,allocate-boot-time");
	client->allocate_on_request = of_property_read_bool(pdev->dev.of_node,
							    "qcom,allocate-on-request");
	client->guard_band = of_property_read_bool(pdev->dev.of_node,
						   "qcom,guard-band");
	client->shared = of_property_read_bool(pdev->dev.of_node, "qcom,shared");
	client->dev = &pdev->dev;
	client->memshare = memshare;

	ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64));
	if (ret)
		return dev_err_probe(&pdev->dev, ret, "failed to set DMA mask\n");

	if (of_find_property(pdev->dev.of_node, "memory-region", NULL)) {
		ret = of_reserved_mem_device_init_by_idx(&pdev->dev,
							 pdev->dev.of_node, 0);
		if (ret)
			return dev_err_probe(&pdev->dev, ret,
					     "failed to attach shared DMA pool\n");
		client->reserved_mem = true;
	}

	mutex_lock(&memshare->lock);
	if (memshare->num_clients >= MEMSHARE_MAX_CLIENTS) {
		ret = -ENOSPC;
		goto unlock;
	}

	for (i = 0; i < memshare->num_clients; i++) {
		if (memshare->clients[i]->client_id == client->client_id &&
		    memshare->clients[i]->proc_id == client->proc_id) {
			ret = -EEXIST;
			goto unlock;
		}
	}

	memshare->clients[memshare->num_clients++] = client;
	platform_set_drvdata(pdev, client);

	if (client->allocate_at_boot && client->configured_size) {
		ret = qcom_memshare_allocate(client, client->configured_size);
		if (ret) {
			memshare->clients[--memshare->num_clients] = NULL;
			goto unlock;
		}
	}

	dev_info(&pdev->dev, "registered client %u proc %u size %u%s\n",
		 client->client_id, client->proc_id, client->configured_size,
		 client->reserved_mem ? " shared-pool" : " CMA");
	ret = 0;

unlock:
	mutex_unlock(&memshare->lock);
	if (ret && client->reserved_mem)
		of_reserved_mem_device_release(&pdev->dev);
	return ret;
}

static void qcom_memshare_child_remove(struct platform_device *pdev)
{
	struct qcom_memshare_client *client = platform_get_drvdata(pdev);
	struct qcom_memshare *memshare;
	unsigned int i;

	if (!client)
		return;

	memshare = client->memshare;
	mutex_lock(&memshare->lock);
	qcom_memshare_release(client);
	for (i = 0; i < memshare->num_clients; i++) {
		if (memshare->clients[i] != client)
			continue;
		memmove(&memshare->clients[i], &memshare->clients[i + 1],
			(memshare->num_clients - i - 1) * sizeof(memshare->clients[0]));
		memshare->clients[--memshare->num_clients] = NULL;
		break;
	}
	mutex_unlock(&memshare->lock);

	if (client->reserved_mem)
		of_reserved_mem_device_release(&pdev->dev);
}

static const struct of_device_id qcom_memshare_child_of_match[] = {
	{ .compatible = "qcom,memshare-peripheral" },
	{ }
};
MODULE_DEVICE_TABLE(of, qcom_memshare_child_of_match);

static struct platform_driver qcom_memshare_child_driver = {
	.probe = qcom_memshare_child_probe,
	.remove = qcom_memshare_child_remove,
	.driver = {
		.name = "qcom-memshare-peripheral",
		.of_match_table = qcom_memshare_child_of_match,
	},
};

static int qcom_memshare_probe(struct platform_device *pdev)
{
	struct qcom_memshare *memshare;
	unsigned int expected_clients;
	int ret;

	memshare = devm_kzalloc(&pdev->dev, sizeof(*memshare), GFP_KERNEL);
	if (!memshare)
		return -ENOMEM;

	memshare->dev = &pdev->dev;
	mutex_init(&memshare->lock);
	platform_set_drvdata(pdev, memshare);

	ret = of_platform_populate(pdev->dev.of_node, NULL, NULL, &pdev->dev);
	if (ret)
		return dev_err_probe(&pdev->dev, ret,
				     "failed to populate clients\n");

	expected_clients = of_get_available_child_count(pdev->dev.of_node);
	if (!expected_clients || memshare->num_clients != expected_clients) {
		ret = -ENODEV;
		goto err_depopulate;
	}

	ret = qmi_handle_init(&memshare->qmi, MEM_FREE_REQ_MAX_MSG_LEN_V01,
			      NULL, qcom_memshare_handlers);
	if (ret)
		goto err_depopulate;
	memshare->qmi_ready = true;

	ret = qmi_add_server(&memshare->qmi, MEMSHARE_SERVICE_ID,
			     MEMSHARE_SERVICE_VERSION,
			     MEMSHARE_SERVICE_INSTANCE);
	if (ret)
		goto err_qmi_release;

	dev_info(&pdev->dev,
		 "registered Dynamic Heap Memory Sharing QMI service with %u clients\n",
		 memshare->num_clients);
	return 0;

err_qmi_release:
	qmi_handle_release(&memshare->qmi);
	memshare->qmi_ready = false;
err_depopulate:
	of_platform_depopulate(&pdev->dev);
	return dev_err_probe(&pdev->dev, ret, "failed to register service\n");
}

static void qcom_memshare_remove(struct platform_device *pdev)
{
	struct qcom_memshare *memshare = platform_get_drvdata(pdev);

	if (memshare->qmi_ready) {
		qmi_handle_release(&memshare->qmi);
		memshare->qmi_ready = false;
	}
	of_platform_depopulate(&pdev->dev);
}

static const struct of_device_id qcom_memshare_of_match[] = {
	{ .compatible = "qcom,memshare" },
	{ }
};
MODULE_DEVICE_TABLE(of, qcom_memshare_of_match);

static struct platform_driver qcom_memshare_driver = {
	.probe = qcom_memshare_probe,
	.remove = qcom_memshare_remove,
	.driver = {
		.name = "qcom-memshare",
		.of_match_table = qcom_memshare_of_match,
	},
};

static int __init qcom_memshare_init(void)
{
	int ret;

	ret = platform_driver_register(&qcom_memshare_child_driver);
	if (ret)
		return ret;

	ret = platform_driver_register(&qcom_memshare_driver);
	if (ret)
		platform_driver_unregister(&qcom_memshare_child_driver);

	return ret;
}
module_init(qcom_memshare_init);

static void __exit qcom_memshare_exit(void)
{
	platform_driver_unregister(&qcom_memshare_driver);
	platform_driver_unregister(&qcom_memshare_child_driver);
}
module_exit(qcom_memshare_exit);

MODULE_DESCRIPTION("Qualcomm Dynamic Heap Memory Sharing QMI service");
MODULE_LICENSE("GPL");
