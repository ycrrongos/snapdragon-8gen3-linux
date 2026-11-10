/* Cerro VOICEMMODE RX+TX HOSTLESS probe. Stop PipeWire first (holds MI2S). */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <agm/agm_api.h>

#define KV_STREAMRX 0xA1000000
#define KV_VOICE_CALL_RX 0xA1000010
#define KV_STREAMTX 0xB1000000
#define KV_VOICE_CALL_TX 0xB1000007
#define KV_VSID 0xB3000000
#define KV_VSID_DEFAULT 0xB3000001
#define KV_DEVICERX 0xA2000000
#define KV_HANDSET_RX 0xA2000004
#define KV_DEVICETX 0xA3000000
#define KV_HANDSET_MIC 0xA3000004
#define KV_PROXY_TX 0xA3000008
#define KV_DEVICEPP_RX 0xAC000000
#define KV_DPP_RX_VOICE 0xAC000005
#define KV_DEVICEPP_TX 0xAD000000
#define KV_DPP_TX_FLUENCE_SMECNS 0xAD000008
#define KV_STREAMPP_RX 0xAF000000
#define KV_SPP_RX_DEFAULT 0xAF000001
#define SESS_RX 106 /* VOICEMMODE1p */
#define SESS_TX 108 /* VOICEMMODE1c */
#define VCPM_MODULE_INSTANCE_ID 0x00000004
#define VCPM_PARAM_ID_VSID 0x080011BC
#define VSID_SUB1 0x11C05000

struct apm_module_param_data_t {
  uint32_t module_instance_id;
  uint32_t param_id;
  uint32_t param_size;
  uint32_t error_code;
};

static uint8_t *build_meta(struct agm_key_value *gkv, uint32_t ng, size_t *out_sz) {
  uint32_t nc = 0, prop_id = 0, num_props = 0;
  size_t sz = 16 + ng * sizeof(*gkv);
  uint8_t *b = calloc(1, sz);
  size_t off = 0;
  if (!b)
    return NULL;
  memcpy(b + off, &ng, 4);
  off += 4;
  memcpy(b + off, gkv, ng * sizeof(*gkv));
  off += ng * sizeof(*gkv);
  memcpy(b + off, &nc, 4);
  off += 4;
  memcpy(b + off, &prop_id, 4);
  off += 4;
  memcpy(b + off, &num_props, 4);
  off += 4;
  *out_sz = off;
  return b;
}

static int find_aif(const char *name, uint32_t *id) {
  struct aif_info list[32];
  size_t num = 32;
  int rc = agm_get_aif_info_list(list, &num);
  if (rc)
    return rc;
  for (size_t i = 0; i < num; i++)
    if (!strcmp(list[i].aif_name, name)) {
      *id = (uint32_t)i;
      return 0;
    }
  return -1;
}

static int set_vsid(uint32_t sess, uint32_t vsid) {
  size_t psz = sizeof(struct apm_module_param_data_t) + sizeof(uint32_t);
  size_t pad = (8 - (psz % 8)) % 8;
  uint8_t *buf = calloc(1, psz + pad);
  struct apm_module_param_data_t *h = (void *)buf;
  uint32_t *v = (uint32_t *)(buf + sizeof(*h));
  h->module_instance_id = VCPM_MODULE_INSTANCE_ID;
  h->param_id = VCPM_PARAM_ID_VSID;
  h->param_size = sizeof(uint32_t);
  *v = vsid;
  int rc = agm_session_set_params(sess, buf, psz + pad);
  free(buf);
  return rc;
}

static int open_dir(uint32_t sess, const char *aif_name, struct agm_key_value *skv,
                    uint32_t nskv, struct agm_key_value *akv, uint32_t nakv,
                    enum direction dir, uint64_t *hout) {
  uint32_t aif = 0;
  size_t msz;
  uint8_t *meta;
  struct agm_media_config mc = {0};
  struct agm_session_config sc = {0};
  struct agm_buffer_config bc = {0};
  uint64_t h = 0;
  int rc;

  if (find_aif(aif_name, &aif)) {
    printf("aif %s missing\n", aif_name);
    return -1;
  }
  mc.rate = 48000;
  mc.channels = 1;
  mc.format = AGM_FORMAT_PCM_S16_LE;
  mc.data_format = AGM_DATA_FORMAT_FIXED_POINT;
  printf("%s aif_media=%d\n", aif_name, agm_aif_set_media_config(aif, &mc));
  meta = build_meta(skv, nskv, &msz);
  agm_session_set_metadata(sess, msz, meta);
  free(meta);
  meta = build_meta(akv, nakv, &msz);
  agm_aif_set_metadata(aif, msz, meta);
  free(meta);
  printf("%s connect=%d\n", aif_name, agm_session_aif_connect(sess, aif, true));
  rc = agm_session_open(sess, AGM_SESSION_NO_HOST, &h);
  printf("%s open=%d h=%llu\n", aif_name, rc, (unsigned long long)h);
  if (!h)
    return rc ? rc : -1;
  sc.sess_mode = AGM_SESSION_NO_HOST;
  sc.data_mode = AGM_DATA_BLOCKING;
  sc.dir = dir;
  printf("%s config=%d\n", aif_name, agm_session_set_config(h, &sc, &mc, &bc));
  printf("%s vsid=%d\n", aif_name, set_vsid(sess, VSID_SUB1));
  printf("%s prepare=%d\n", aif_name, agm_session_prepare(h));
  printf("%s start=%d\n", aif_name, agm_session_start(h));
  *hout = h;
  return 0;
}

int main(int argc, char **argv) {
  setvbuf(stdout, NULL, _IONBF, 0);
  int hold = (argc > 1) ? atoi(argv[1]) : 30;
  int use_proxy = (argc > 2) && !strcmp(argv[2], "proxy");
  uint64_t hr = 0, ht = 0;
  int rc;

  struct agm_key_value sess_rx[] = {{KV_STREAMRX, KV_VOICE_CALL_RX},
                                    {KV_STREAMPP_RX, KV_SPP_RX_DEFAULT},
                                    {KV_VSID, KV_VSID_DEFAULT}};
  struct agm_key_value aif_rx[] = {{KV_DEVICERX, KV_HANDSET_RX},
                                   {KV_DEVICEPP_RX, KV_DPP_RX_VOICE}};
  struct agm_key_value sess_tx[] = {{KV_STREAMTX, KV_VOICE_CALL_TX},
                                    {KV_VSID, KV_VSID_DEFAULT}};
  struct agm_key_value aif_tx_fl[] = {{KV_DEVICETX, KV_HANDSET_MIC},
                                      {KV_DEVICEPP_TX, KV_DPP_TX_FLUENCE_SMECNS}};
  struct agm_key_value aif_tx_px[] = {{KV_DEVICETX, KV_PROXY_TX}};

  rc = agm_init();
  printf("agm_init=%d\n", rc);
  if (rc)
    return 1;

  if (open_dir(SESS_RX, "MI2S-LPAIF-RX-PRIMARY", sess_rx, 3, aif_rx, 2, RX,
               &hr) ||
      !hr) {
    printf("RX open failed — exit (do not hold leftover graphs)\n");
    return 2;
  }

  if (use_proxy)
    open_dir(SESS_TX, "CODEC_DMA-LPAIF_RXTX-TX-3", sess_tx, 2, aif_tx_px, 1, TX,
             &ht);
  else
    open_dir(SESS_TX, "CODEC_DMA-LPAIF_RXTX-TX-3", sess_tx, 2, aif_tx_fl, 2, TX,
             &ht);

  printf("holding %ds (dial/answer now)\n", hold);
  sleep(hold);
  if (ht) {
    printf("tx stop=%d close=%d\n", agm_session_stop(ht), agm_session_close(ht));
  }
  if (hr) {
    printf("rx stop=%d close=%d\n", agm_session_stop(hr), agm_session_close(hr));
  }
  printf("done\n");
  return 0;
}
