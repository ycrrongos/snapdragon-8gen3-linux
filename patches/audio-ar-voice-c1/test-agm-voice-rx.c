#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <agm/agm_api.h>

#define KV_STREAMRX 0xA1000000
#define KV_VOICE_CALL_RX 0xA1000010
#define KV_VSID 0xB3000000
#define KV_VSID_DEFAULT 0xB3000001
#define KV_DEVICERX 0xA2000000
#define KV_HANDSET 0xA2000004
#define KV_DEVICEPP_RX 0xAC000000
#define KV_DPP_RX_VOICE 0xAC000005
#define KV_STREAMPP_RX 0xAF000000
#define KV_SPP_RX_DEFAULT 0xAF000001
#define SESS_RX 106
#define VCPM_MODULE_INSTANCE_ID 0x00000004
#define VCPM_PARAM_ID_VSID 0x080011BC
#define VSID_SUB1 0x11C05000

struct apm_module_param_data_t {
  uint32_t module_instance_id;
  uint32_t param_id;
  uint32_t param_size;
  uint32_t error_code;
};

static uint8_t *build_meta(struct agm_key_value *gkv, uint32_t ng, size_t *out_sz){
  uint32_t nc=0,prop_id=0,num_props=0;
  size_t sz=16+ng*sizeof(*gkv);
  uint8_t *b=calloc(1,sz); size_t off=0;
  if(!b)return NULL;
  memcpy(b+off,&ng,4);off+=4;
  memcpy(b+off,gkv,ng*sizeof(*gkv));off+=ng*sizeof(*gkv);
  memcpy(b+off,&nc,4);off+=4;
  memcpy(b+off,&prop_id,4);off+=4;
  memcpy(b+off,&num_props,4);off+=4;
  *out_sz=off; return b;
}
static int find_aif(const char *name,uint32_t *id){
  struct aif_info list[32]; size_t num=32;
  int rc=agm_get_aif_info_list(list,&num); if(rc)return rc;
  for(size_t i=0;i<num;i++)
    if(!strcmp(list[i].aif_name,name)){*id=(uint32_t)i;return 0;}
  return -1;
}
static int set_vsid(uint32_t sess, uint32_t vsid){
  size_t psz = sizeof(struct apm_module_param_data_t) + sizeof(uint32_t);
  size_t pad = (8 - (psz % 8)) % 8;
  uint8_t *buf = calloc(1, psz + pad);
  struct apm_module_param_data_t *h = (void*)buf;
  uint32_t *v = (uint32_t*)(buf + sizeof(*h));
  h->module_instance_id = VCPM_MODULE_INSTANCE_ID;
  h->param_id = VCPM_PARAM_ID_VSID;
  h->param_size = sizeof(uint32_t);
  h->error_code = 0;
  *v = vsid;
  int rc = agm_session_set_params(sess, buf, psz+pad);
  free(buf);
  return rc;
}
int main(int argc, char **argv){
  setvbuf(stdout,NULL,_IONBF,0);
  int hold = (argc>1)?atoi(argv[1]):25;
  uint32_t aif=0; uint64_t h=0; size_t msz; uint8_t *meta; int rc;
  struct agm_media_config mc={0};
  struct agm_session_config sc={0};
  struct agm_buffer_config bc={0};
  struct agm_key_value sess[]={
    {KV_STREAMRX,KV_VOICE_CALL_RX},
    {KV_STREAMPP_RX,KV_SPP_RX_DEFAULT},
    {KV_VSID,KV_VSID_DEFAULT}};
  struct agm_key_value aifkv[]={
    {KV_DEVICERX,KV_HANDSET},
    {KV_DEVICEPP_RX,KV_DPP_RX_VOICE}};

  rc=agm_init(); printf("agm_init=%d\n",rc); if(rc)return 1;
  find_aif("MI2S-LPAIF-RX-PRIMARY",&aif);
  mc.rate=48000; mc.channels=1;
  mc.format=AGM_FORMAT_PCM_S16_LE;
  mc.data_format=AGM_DATA_FORMAT_FIXED_POINT;
  printf("aif_media=%d\n", agm_aif_set_media_config(aif,&mc));
  meta=build_meta(sess,3,&msz); agm_session_set_metadata(SESS_RX,msz,meta); free(meta);
  meta=build_meta(aifkv,2,&msz); agm_aif_set_metadata(aif,msz,meta); free(meta);
  printf("connect=%d\n", agm_session_aif_connect(SESS_RX,aif,true));
  rc=agm_session_open(SESS_RX,AGM_SESSION_NO_HOST,&h);
  printf("open=%d h=%llu\n",rc,(unsigned long long)h); if(!h)return 2;
  sc.sess_mode=AGM_SESSION_NO_HOST; sc.data_mode=AGM_DATA_BLOCKING; sc.dir=RX;
  printf("config=%d\n", agm_session_set_config(h,&sc,&mc,&bc));
  printf("vsid=%d\n", set_vsid(SESS_RX, VSID_SUB1));
  printf("prepare=%d\n", agm_session_prepare(h));
  printf("start=%d\n", agm_session_start(h));
  printf("RX graph started; holding %ds (dial externally or via mmcli)\n", hold);
  sleep(hold);
  printf("stop=%d\n", agm_session_stop(h));
  printf("close=%d\n", agm_session_close(h));
  printf("done\n");
  return 0;
}
