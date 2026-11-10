/* Smoke test: open aud_pasthru_adsp, send APM get-SPF-state, wait for reply.
 * Build on phone: cc -O2 -o test-apm-ping test-apm-ping.c
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <poll.h>

/* mainline audioreach.h */
#define APM_CMD_GET_SPF_STATE		0x01001021
#define APM_CMD_RSP_GET_SPF_STATE	0x02001007

struct gpr_hdr {
	uint32_t version:4;
	uint32_t hdr_size:4;
	uint32_t pkt_size:24;
	uint32_t dest_domain:8;
	uint32_t src_domain:8;
	uint32_t reserved:16;
	uint32_t src_port;
	uint32_t dest_port;
	uint32_t token;
	uint32_t opcode;
} __attribute__((packed));

int main(void)
{
	int fd = open("/dev/aud_pasthru_adsp", O_RDWR | O_NONBLOCK);
	struct gpr_hdr pkt;
	uint8_t buf[4096];
	struct pollfd pfd;
	ssize_t n;

	if (fd < 0) {
		perror("open aud_pasthru_adsp");
		return 1;
	}

	memset(&pkt, 0, sizeof(pkt));
	pkt.version = 0;
	pkt.hdr_size = sizeof(pkt) / 4;
	pkt.pkt_size = sizeof(pkt);
	pkt.dest_domain = 2; /* ADSP */
	pkt.src_domain = 3;  /* APPS — driver may rewrite */
	pkt.src_port = 0;    /* driver rewrites to dynamic port */
	pkt.dest_port = 1;   /* APM module IID */
	pkt.token = 0xce110;
	pkt.opcode = APM_CMD_GET_SPF_STATE;

	n = write(fd, &pkt, sizeof(pkt));
	if (n < 0) {
		perror("write");
		return 2;
	}
	printf("sent GET_SPF_STATE (%zd bytes)\n", n);

	pfd.fd = fd;
	pfd.events = POLLIN;
	if (poll(&pfd, 1, 3000) <= 0) {
		fprintf(stderr, "timeout/no response\n");
		return 3;
	}
	n = read(fd, buf, sizeof(buf));
	if (n < (ssize_t)sizeof(struct gpr_hdr)) {
		perror("read");
		return 4;
	}
	{
		struct gpr_hdr *rh = (struct gpr_hdr *)buf;
		printf("rsp opcode=0x%08x pkt_size=%u src_port=%u dest_port=%u\n",
		       rh->opcode, rh->pkt_size, rh->src_port, rh->dest_port);
		if (rh->opcode == APM_CMD_RSP_GET_SPF_STATE)
			printf("PASS: APM answered via aud_pasthru_adsp\n");
		else
			printf("got unexpected opcode (still path alive)\n");
	}
	close(fd);
	return 0;
}
