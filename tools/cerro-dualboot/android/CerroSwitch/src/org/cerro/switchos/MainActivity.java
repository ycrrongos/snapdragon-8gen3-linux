package org.cerro.switchos;

import android.app.*;
import android.content.Intent;
import android.os.*;
import android.view.*;
import android.widget.*;
import java.util.*;
import java.util.concurrent.*;

public class MainActivity extends Activity {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private TextView status, details;
    private Spinner images;
    private Button refresh, switchButton, recoverButton;
    private boolean reading = false, visible = false, writingRequested = false;
    private final List<String> names = new ArrayList<>();
    private final Runnable poll = new Runnable() {
        public void run() {
            if (!visible) return;
            if (!SwitchService.transcript.isEmpty()) details.setText(SwitchService.transcript);
            if (!SwitchService.busy.get() && !SwitchService.transcript.equals("正在启动切换服务…")) writingRequested = false;
            enabled(); handler.postDelayed(this, 600);
        }
    };
    private int dp(int v) { return Math.round(v * getResources().getDisplayMetrics().density); }
    private TextView text(String value, int size) {
        TextView view = new TextView(this); view.setText(value); view.setTextSize(size);
        view.setPadding(0, dp(8), 0, dp(8)); return view;
    }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state); setTitle("系统切换");
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        ScrollView scroll = new ScrollView(this);
        LinearLayout root = new LinearLayout(this); root.setOrientation(LinearLayout.VERTICAL); root.setPadding(dp(22), dp(18), dp(22), dp(26));
        scroll.addView(root); setContentView(scroll);
        root.addView(text("Android → Linux", 27));
        root.addView(text("保持当前活动槽切换。Android 的 boot 和 dtbo 会先备份到另一槽；切回时恢复这两个分区。", 16));
        status = text("需要 KernelSU / Magisk root 授权。", 15); root.addView(status);
        root.addView(text("内部存储 / linuxkernel", 19));
        root.addView(text("把已打包的 Linux boot .img 放到这个目录，再选择镜像。支持多个文件。", 15));
        images = new Spinner(this); images.setMinimumHeight(dp(56)); root.addView(images);
        refresh = new Button(this); refresh.setText("授权 root 并刷新镜像"); root.addView(refresh);
        switchButton = new Button(this); switchButton.setText("预览并切换到 Linux"); root.addView(switchButton);
        recoverButton = new Button(this); recoverButton.setText("恢复 Android（用于中断恢复）"); root.addView(recoverButton);
        details = text("应用构建版，尚未在手机上实测切换。\n备份保存在 Linux 分区的私有目录；无有效清单、校验不符或写入失败会停止。", 14);
        details.setTextIsSelectable(true); root.addView(details);
        refresh.setOnClickListener(v -> refresh());
        switchButton.setOnClickListener(v -> previewLinux());
        recoverButton.setOnClickListener(v -> previewRecovery());
        enabled();
    }
    @Override protected void onResume() { super.onResume(); visible = true; handler.post(poll); }
    @Override protected void onPause() { visible = false; handler.removeCallbacks(poll); super.onPause(); }
    private void enabled() {
        boolean available = !reading && !writingRequested && !SwitchService.busy.get();
        refresh.setEnabled(available); images.setEnabled(available);
        switchButton.setEnabled(available && !names.isEmpty()); recoverButton.setEnabled(available);
    }
    private interface Work { void run() throws Exception; }
    private void async(Work work) {
        reading = true; enabled(); status.setText("正在请求 root 并读取校验信息…");
        worker.execute(() -> {
            try { work.run(); }
            catch (Exception error) { handler.post(() -> { status.setText("操作未完成"); details.setText(error.getMessage()); }); }
            finally { handler.post(() -> { reading = false; enabled(); }); }
        });
    }
    private void refresh() {
        async(() -> {
            String result = RootBackend.run(this, null, "images");
            String info = RootBackend.run(this, null, "status");
            List<String> found = new ArrayList<>();
            for (String name : result.split("\n")) if (!name.isEmpty() && name.endsWith(".img") && !name.contains("/")) found.add(name);
            Collections.sort(found);
            handler.post(() -> {
                names.clear(); names.addAll(found);
                images.setAdapter(new ArrayAdapter<>(this, android.R.layout.simple_spinner_dropdown_item, names));
                status.setText(info); details.setText(names.isEmpty() ? "目录中没有 .img。请先放入 Linux boot 镜像，再刷新。" : "选择镜像后可预览完整切换计划和 SHA256。");
            });
        });
    }
    private void previewLinux() {
        int index = images.getSelectedItemPosition(); if (index < 0 || index >= names.size()) return;
        String image = "/data/media/0/linuxkernel/" + names.get(index);
        async(() -> {
            String plan = RootBackend.run(this, null, "plan-linux", image);
            String sha = "";
            for (String line : plan.split("\n")) if (line.startsWith("SHA256=")) sha = line.substring(7);
            if (!sha.matches("[0-9a-f]{64}")) throw new Exception("未取得有效镜像 SHA256，未写入。");
            final String digest = sha;
            handler.post(() -> {
                status.setText("计划已读取，尚未写入分区"); details.setText(plan);
                new AlertDialog.Builder(this).setTitle("切换到 Linux？")
                    .setMessage(plan + "\n\n会覆盖非活动槽的 boot/dtbo 作为 Android 缓存，完整原件另存备份；全部读回校验后重启。")
                    .setNegativeButton("取消", null).setPositiveButton("备份、切换并重启", (d,w) -> start("switch-linux", image, digest)).show();
            });
        });
    }
    private void previewRecovery() {
        async(() -> {
            String plan = RootBackend.run(this, null, "plan-android");
            handler.post(() -> new AlertDialog.Builder(this).setTitle("恢复 Android？").setMessage(plan)
                .setNegativeButton("取消",null).setPositiveButton("按清单恢复",(d,w)->start("switch-android")).show());
        });
    }
    private void start(String... arguments) {
        writingRequested = true;
        SwitchService.transcript = "正在启动切换服务…";
        Intent intent = new Intent(this, SwitchService.class); intent.putExtra("arguments", arguments);
        try { startForegroundService(intent); }
        catch (Exception error) { writingRequested = false; details.setText(error.getMessage()); }
        enabled();
    }
}
