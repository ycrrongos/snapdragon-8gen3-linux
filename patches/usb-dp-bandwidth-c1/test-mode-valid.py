#!/usr/bin/env python3
"""Compile the actual kernel DP validation functions with small transport stubs.

Covers normal negotiated video, not the DP compliance-test bpp override.
No phone access or source rewriting. Pass an alternate kernel tree as argv[1].
"""
from pathlib import Path
import re
import subprocess
import sys
import tempfile

kernel = Path(sys.argv[1] if len(sys.argv) > 1 else 'build/linux-7.2')
dp = kernel / 'drivers/gpu/drm/msm/dp'

def function(path, name):
    source = path.read_text()
    match = re.search(r'^(?:static )?(?:enum drm_mode_status|u32)\s+' + name + r'\(', source, re.M)
    assert match, name
    opening = source.index('{', match.start())
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end]

limit = re.search(r'#define DP_MAX_PIXEL_CLK_KHZ\s+(\d+)', (dp / 'dp_display.h').read_text()).group(1)
source = r'''
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <errno.h>
typedef uint32_t u32;
#define min(a,b) ((a)<(b)?(a):(b))
#define DRM_ERROR(...) ((void)0)
#define container_of(p,t,m) ((t *)((char *)(p)-offsetof(t,m)))
enum drm_mode_status { MODE_OK, MODE_CLOCK_HIGH, MODE_BAD, MODE_NO_420 };
struct drm_display_info { u32 bpc; bool only420; };
struct drm_display_mode { int clock; };
struct drm_connector { struct drm_display_info display_info; };
struct msm_dp_link_info { u32 num_lanes, rate; };
struct msm_dp_panel { struct msm_dp_link_info link_info; bool vsc_sdp_supported; };
struct msm_dp { struct drm_connector *connector; };
struct drm_bridge { struct msm_dp *msm_dp_display; };
#define to_dp_bridge(b) (b)
struct msm_dp_display_private {
    struct msm_dp msm_dp_display;
    struct msm_dp_panel *panel;
    bool wide_bus_supported, active420;
};
static bool drm_mode_is_420_only(const struct drm_display_info *i, const struct drm_display_mode *m) { return i->only420; }
static bool msm_dp_wide_bus_available(struct msm_dp *dp) {
    struct msm_dp_display_private *p = container_of(dp, struct msm_dp_display_private, msm_dp_display);
    return p->wide_bus_supported && !p->active420;
}
'''
source += f'\n#define DP_MAX_PIXEL_CLK_KHZ {limit}\n'
source += function(dp / 'dp_panel.c', 'msm_dp_panel_get_supported_bpp')
source += r'''
static u32 msm_dp_panel_get_mode_bpp(struct msm_dp_panel *p, u32 bpp, u32 clock) {
    return msm_dp_panel_get_supported_bpp(p, bpp, clock);
}
'''
source += function(dp / 'dp_display.c', 'msm_dp_bridge_mode_valid')
source += r'''
struct testcase {
    const char *name;
    int clock, lanes, rate, bpc;
    bool wide, only420, vsc, active420;
    enum drm_mode_status expected;
};
int main(void) {
    const struct testcase cases[] = {
        {"HDMI 2-lane RGB 4K60 exceeds link",537300,2,540000,10,true,false,true,false,MODE_BAD},
        {"direct 4-lane RGB 4K60 fits",537300,4,540000,10,true,false,true,false,MODE_OK},
        {"HDMI 2-lane RGB 4K30 fits",297000,2,540000,10,true,false,true,false,MODE_OK},
        {"HDMI 2-lane RGB 1080p60 fits",148500,2,540000,10,true,false,true,false,MODE_OK},
        {"420-only with VSC uses half link pixels",594000,2,540000,8,true,true,true,false,MODE_OK},
        {"420-only without VSC rejected",594000,2,540000,8,true,true,false,false,MODE_NO_420},
        {"wide bus still permits high interface clock",900000,4,810000,8,true,false,true,false,MODE_OK},
        {"narrow interface clock limit retained",900000,4,810000,8,false,false,true,false,MODE_CLOCK_HIGH},
        {"candidate clock independent of active 420",900000,4,810000,8,true,false,true,true,MODE_OK},
        {"wide bus cannot rescue over-budget RGB",1300000,2,540000,8,true,false,true,false,MODE_BAD},
    };
    int fails = 0;
    for (unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++) {
        const struct testcase *t = &cases[i];
        struct drm_connector connector = { .display_info = {t->bpc,t->only420} };
        struct msm_dp_panel panel = { .link_info={t->lanes,t->rate}, .vsc_sdp_supported=t->vsc };
        struct msm_dp_display_private display = { .msm_dp_display={&connector}, .panel=&panel,
            .wide_bus_supported=t->wide, .active420=t->active420 };
        struct drm_bridge bridge = { &display.msm_dp_display };
        struct drm_display_mode mode = { t->clock };
        int actual = msm_dp_bridge_mode_valid(&bridge,&connector.display_info,&mode);
        printf("%s: %s (actual=%d expected=%d)\n",actual==t->expected?"PASS":"FAIL",t->name,actual,t->expected);
        fails += actual != t->expected;
    }
    return fails != 0;
}
'''
with tempfile.TemporaryDirectory(prefix='cerro-dp-mode-valid-') as work:
    work = Path(work)
    (work / 'test.c').write_text(source)
    subprocess.run(['cc', '-std=c11', '-Wall', '-Wno-unused-function', '-o', str(work / 'test'), str(work / 'test.c')], check=True)
    raise SystemExit(subprocess.run([str(work / 'test')]).returncode)
