/**
 * ar_osal_shmem_cerro.c — drop-in replacement for ar_osal_shmem_virtual.c
 * Uses /dev/cerro_audio_shmem for physical CMA + hyp_assign.
 *
 * Build into libar-osal instead of ar_osal_shmem_virtual.c.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <pthread.h>
#include "ar_osal_shmem.h"
#include "ar_osal_error.h"
#include "ar_osal_log.h"

#define AR_OSAL_SHMEM_LOG_TAG "COSH"
#define SHMEM_4K_ALIGNMENT 4096
#define CERRO_SHMEM_PATH "/dev/cerro_audio_shmem"

#define CERRO_SHMEM_IOC_MAGIC 'C'
struct cerro_shmem_alloc_req {
	uint32_t size;
	uint32_t flags;
	uint64_t phys;
	uint32_t id;
	uint32_t pad;
};
#define CERRO_SHMEM_ALLOC    _IOWR(CERRO_SHMEM_IOC_MAGIC, 1, struct cerro_shmem_alloc_req)
#define CERRO_SHMEM_FREE     _IOW(CERRO_SHMEM_IOC_MAGIC, 2, uint32_t)

struct cerro_meta {
	int fd;
	uint32_t id;
	size_t size;
};

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

int32_t ar_shmem_validate_sys_id(uint8_t num_sys_id, ar_shmem_proc_info *sys_id)
{
	int32_t status = AR_EOK;
	uint8_t i;

	if (!num_sys_id || !sys_id)
		return AR_EBADPARAM;
	for (i = 0; i < num_sys_id; i++) {
		if (sys_id[i].proc_id != AR_AUDIO_DSP &&
		    sys_id[i].proc_id != AR_MODEM_DSP &&
		    sys_id[i].proc_id != AR_SENSOR_DSP &&
		    sys_id[i].proc_id != AR_COMPUTE_DSP &&
		    sys_id[i].proc_id != AR_APSS &&
		    sys_id[i].proc_id != AR_APSS2) {
			status = AR_EBADPARAM;
			break;
		}
	}
	return status;
}

int32_t ar_shmem_init(void)
{
	return access(CERRO_SHMEM_PATH, R_OK | W_OK) == 0 ? AR_EOK : AR_ENOTEXIST;
}

int32_t ar_shmem_init_v2(uint32_t num_master_procs, uint32_t *master_procs)
{
	(void)num_master_procs;
	(void)master_procs;
	return ar_shmem_init();
}

int32_t ar_shmem_deinit(void)
{
	return AR_EOK;
}

int32_t ar_shmem_alloc(ar_shmem_info *info)
{
	struct cerro_shmem_alloc_req req;
	struct cerro_meta *meta;
	int fd, rc;
	void *map;

	if (!info || !info->buf_size)
		return AR_EBADPARAM;
	if (ar_shmem_validate_sys_id(info->num_sys_id, info->sys_id))
		return AR_EBADPARAM;

	pthread_mutex_lock(&lock);
	fd = open(CERRO_SHMEM_PATH, O_RDWR | O_CLOEXEC);
	if (fd < 0) {
		AR_LOG_ERR(AR_OSAL_SHMEM_LOG_TAG, "open %s failed errno=%d",
			   CERRO_SHMEM_PATH, errno);
		pthread_mutex_unlock(&lock);
		return AR_ENOTEXIST;
	}

	memset(&req, 0, sizeof(req));
	req.size = (uint32_t)((info->buf_size + SHMEM_4K_ALIGNMENT - 1) &
			      ~(SHMEM_4K_ALIGNMENT - 1));
	rc = ioctl(fd, CERRO_SHMEM_ALLOC, &req);
	if (rc) {
		AR_LOG_ERR(AR_OSAL_SHMEM_LOG_TAG, "CERRO_SHMEM_ALLOC failed %d errno=%d",
			   rc, errno);
		close(fd);
		pthread_mutex_unlock(&lock);
		return AR_ENOMEMORY;
	}

	map = mmap(NULL, req.size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (map == MAP_FAILED) {
		AR_LOG_ERR(AR_OSAL_SHMEM_LOG_TAG, "mmap failed errno=%d", errno);
		ioctl(fd, CERRO_SHMEM_FREE, &req.id);
		close(fd);
		pthread_mutex_unlock(&lock);
		return AR_ENOMEMORY;
	}

	meta = calloc(1, sizeof(*meta));
	if (!meta) {
		munmap(map, req.size);
		ioctl(fd, CERRO_SHMEM_FREE, &req.id);
		close(fd);
		pthread_mutex_unlock(&lock);
		return AR_ENOMEMORY;
	}
	meta->fd = fd;
	meta->id = req.id;
	meta->size = req.size;

	info->vaddr = map;
	info->buf_size = req.size;
	info->mem_type = AR_SHMEM_PHYSICAL_MEMORY;
	info->index_type = AR_SHMEM_BUFFER_ADDRESS;
	info->pa_lsw = (uint32_t)(req.phys & 0xffffffffu);
	info->pa_msw = (uint32_t)(req.phys >> 32);
	info->ipa_lsw = info->pa_lsw;
	info->ipa_msw = info->pa_msw;
	info->metadata = (uint64_t)(uintptr_t)meta;

	AR_LOG_INFO(AR_OSAL_SHMEM_LOG_TAG,
		    "cerro shmem id=%u sz=0x%x pa=0x%x%08x vaddr=%p",
		    meta->id, (unsigned)req.size, info->pa_msw, info->pa_lsw, map);
	pthread_mutex_unlock(&lock);
	return AR_EOK;
}

int32_t ar_shmem_free(ar_shmem_info *info)
{
	struct cerro_meta *meta;

	if (!info || !info->metadata)
		return AR_EBADPARAM;
	pthread_mutex_lock(&lock);
	meta = (struct cerro_meta *)(uintptr_t)info->metadata;
	if (info->vaddr && meta->size)
		munmap(info->vaddr, meta->size);
	ioctl(meta->fd, CERRO_SHMEM_FREE, &meta->id);
	close(meta->fd);
	free(meta);
	info->metadata = 0;
	info->vaddr = NULL;
	pthread_mutex_unlock(&lock);
	return AR_EOK;
}

int32_t ar_shmem_map(ar_shmem_info *info)
{
	if (!info || !info->buf_size || (!info->pa_lsw && !info->pa_msw))
		return AR_EBADPARAM;
	info->ipa_lsw = info->pa_lsw;
	info->ipa_msw = info->pa_msw;
	return AR_EOK;
}

int32_t ar_shmem_unmap(ar_shmem_info *info)
{
	(void)info;
	return AR_EOK;
}

int32_t ar_shmem_hyp_assign_phys(ar_shmem_hyp_assign_phys_info *info)
{
	(void)info;
	return AR_EOK;
}

int32_t ar_shmem_get_uid(uint64_t alloc_handle, uint64_t *uid)
{
	if (!uid)
		return AR_EFAILED;
	*uid = alloc_handle;
	return AR_EOK;
}
