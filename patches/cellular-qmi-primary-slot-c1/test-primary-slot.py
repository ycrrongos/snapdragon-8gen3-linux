#!/usr/bin/env python3
"""Compile the actual selection function/block against libqmi's slot type.
Usage: test-primary-slot.py /path/to/src/mm-shared-qmi.c
The original 1.24 selection must fail DSDS fixtures; patched selection must pass.
"""
import pathlib,re,shlex,subprocess,sys,tempfile
s=pathlib.Path(sys.argv[1]).read_text()
if 'find_primary_active_slot (GArray *physical_slots)' in s:
 start=s.index('static guint\nfind_primary_active_slot (')
 end=s.index('\nstatic void\nuim_get_slot_status_ready',start)
 function=s[start:end]
else:
 block=re.search(r'        if \(slot_status->physical_slot_status == QMI_UIM_SLOT_STATE_ACTIVE\) \{\n            sim_active = TRUE;\n            ctx->active_logical_id = slot_status->logical_slot;\n            ctx->active_slot_number = i \+ 1;\n        \}',s)
 assert block,'original selection not found'
 function='''static guint find_primary_active_slot(GArray *physical_slots) {
 struct {guint active_logical_id, active_slot_number;} state={0}, *ctx=&state;
 gboolean sim_active=FALSE;
 for(guint i=0;i<physical_slots->len;i++) {
 QmiPhysicalSlotStatusSlot *slot_status=&g_array_index(physical_slots,QmiPhysicalSlotStatusSlot,i);
 '''+block.group(0)+'''
 }
 (void)sim_active;
 return ctx->active_slot_number;
 }
'''
test=r'''
struct fixture {const char *name; guint active[3], logical[3], expected;};
int main(void) {
 struct fixture cases[]={
 {"no active slots",{0,0,0},{0,0,0},0},
 {"single SIM physical 1",{1,0,0},{1,0,0},1},
 {"single SIM physical 2",{0,1,0},{0,1,0},2},
 {"Cerro DSDS primary then secondary",{1,1,0},{1,2,0},1},
 {"DSDS primary mapped to physical 2",{1,1,0},{2,1,0},2},
 {"three standby subscriptions",{1,1,1},{1,2,3},1},
 {"physical ordering independent",{1,1,1},{3,1,2},2},
 {"inactive slot is not primary",{0,1,0},{1,2,0},2},
 {"zero logical ID is invalid",{1,0,0},{0,0,0},0},
 };
 guint failed=0;
 for(guint k=0;k<G_N_ELEMENTS(cases);k++) {
  GArray *slots=g_array_new(FALSE,TRUE,sizeof(QmiPhysicalSlotStatusSlot));
  for(guint i=0;i<3;i++) {
   QmiPhysicalSlotStatusSlot slot={0};
   slot.physical_slot_status=cases[k].active[i]?QMI_UIM_SLOT_STATE_ACTIVE:QMI_UIM_SLOT_STATE_INACTIVE;
   slot.logical_slot=cases[k].logical[i];
   g_array_append_val(slots,slot);
  }
  guint actual=find_primary_active_slot(slots);
  gboolean ok=actual==cases[k].expected;
  g_print("%s %s: actual=%u expected=%u\n",ok?"PASS":"FAIL",cases[k].name,actual,cases[k].expected);
  failed+=!ok;g_array_unref(slots);
 }
 g_print("%u/%u passed\n",(guint)G_N_ELEMENTS(cases)-failed,(guint)G_N_ELEMENTS(cases));
 return failed?1:0;
}
'''
with tempfile.TemporaryDirectory() as d:
 p=pathlib.Path(d);(p/'test.c').write_text('#include <libqmi-glib.h>\n'+function+test)
 flags=shlex.split(subprocess.check_output(['pkg-config','--cflags','--libs','qmi-glib'],text=True))
 subprocess.run(['cc','-Wall','-Wextra','-Werror',str(p/'test.c'),'-o',str(p/'test')]+flags,check=True)
 sys.exit(subprocess.run([str(p/'test')]).returncode)
