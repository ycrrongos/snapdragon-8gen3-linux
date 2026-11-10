package org.cerro.switchos;

import android.app.Activity;
import android.app.AlertDialog;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.widget.Button;
import android.widget.TextView;
import android.widget.Toast;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

public class MainActivity extends Activity {
    private TextView status;
    private final Handler handler = new Handler(Looper.getMainLooper());

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        status = findViewById(R.id.status);
        Button btn = findViewById(R.id.btn);
        btn.setOnClickListener(v -> confirm());
        refreshHint();
    }

    private void refreshHint() {
        new Thread(() -> {
            String slot = prop("ro.boot.slot_suffix");
            String img = shell("su", "-c",
                "if [ -f /data/adb/cerro/linux-boot.img ]; then echo ok:/data/adb/cerro/linux-boot.img;"
                + " elif [ -f /data/cerro-dualboot/linux-boot.img ]; then echo ok:/data/cerro-dualboot/linux-boot.img;"
                + " elif [ -f /data/cerro-dualboot/linux-daily.img ]; then echo ok:/data/cerro-dualboot/linux-daily.img;"
                + " else echo missing; fi");
            handler.post(() -> status.setText(
                "活动槽: " + (slot.isEmpty() ? "(未知)" : slot) + "\n"
                + "Linux boot: " + img + "\n\n"
                + "将把活动槽 Android boot 复制到非活动槽，再把 Linux boot 刷入活动槽并重启。"));
        }).start();
    }

    private void confirm() {
        new AlertDialog.Builder(this)
            .setTitle("切换到 Linux？")
            .setMessage("会改写 boot 分区并立即重启。请确认已授权 KernelSU root，且已放置 linux-boot.img。")
            .setPositiveButton("切换并重启", (d, w) -> doSwitch())
            .setNegativeButton("取消", null)
            .show();
    }

    private void doSwitch() {
        status.setText("切换中…");
        new Thread(() -> {
            // Prefer embedded script path if installed; else inline
            String out = shell("su", "-c",
                "SCRIPT=/data/adb/cerro/switch-to-linux-bootswap.sh; "
                + "if [ -x \"$SCRIPT\" ]; then \"$SCRIPT\"; else "
                + "BY=/dev/block/by-name; "
                + "IMG=/data/adb/cerro/linux-boot.img; "
                + "[ -f \"$IMG\" ] || IMG=/data/cerro-dualboot/linux-boot.img; "
                + "[ -f \"$IMG\" ] || IMG=/data/cerro-dualboot/linux-daily.img; "
                + "[ -f \"$IMG\" ] || { echo missing-img; exit 2; }; "
                + "S=$(getprop ro.boot.slot_suffix); "
                + "case \"$S\" in _a) A=a;I=b;; _b) A=b;I=a;; *) echo bad-slot; exit 3;; esac; "
                + "dd if=$BY/boot_$A of=$BY/boot_$I bs=4M status=none conv=fsync && "
                + "dd if=$IMG of=$BY/boot_$A bs=4M status=none conv=fsync && "
                + "sync && reboot; fi");
            handler.post(() -> {
                status.setText(out);
                Toast.makeText(this, out, Toast.LENGTH_LONG).show();
            });
        }).start();
    }

    private static String prop(String k) {
        return shell("getprop", k).trim();
    }

    private static String shell(String... cmd) {
        try {
            Process p = new ProcessBuilder(cmd).redirectErrorStream(true).start();
            StringBuilder sb = new StringBuilder();
            try (BufferedReader br = new BufferedReader(
                    new InputStreamReader(p.getInputStream(), StandardCharsets.UTF_8))) {
                String line;
                while ((line = br.readLine()) != null) {
                    sb.append(line).append('\n');
                }
            }
            p.waitFor();
            return sb.toString().trim();
        } catch (Exception e) {
            return "ERR: " + e.getMessage();
        }
    }
}
