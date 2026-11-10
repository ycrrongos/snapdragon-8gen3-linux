package org.cerro.switchos;

import android.app.*;
import android.content.Intent;
import android.os.*;
import java.util.concurrent.atomic.AtomicBoolean;

public class SwitchService extends Service {
    static final AtomicBoolean busy = new AtomicBoolean(false);
    static volatile String transcript = "";
    private static final String CHANNEL = "system-switch";
    private PowerManager.WakeLock wakeLock;
    private synchronized void append(String line) {
        transcript = transcript + line + "\n";
        if (transcript.length() > 24000) transcript = transcript.substring(transcript.length() - 24000);
    }
    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || !busy.compareAndSet(false, true)) return START_NOT_STICKY;
        String[] args = intent.getStringArrayExtra("arguments");
        if (args == null || args.length == 0 || !(args[0].equals("switch-linux") || args[0].equals("switch-android"))) {
            busy.set(false); stopSelf(); return START_NOT_STICKY;
        }
        transcript = "正在执行已确认的同槽切换…\n请保留电量，不要强制重启。\n";
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(new NotificationChannel(CHANNEL, "系统切换进度", NotificationManager.IMPORTANCE_LOW));
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class), PendingIntent.FLAG_IMMUTABLE);
        startForeground(12, new Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_notify_sync).setContentTitle("系统切换中")
            .setContentText("正在备份和校验分区，请勿关机").setContentIntent(open).setOngoing(true).build());
        wakeLock = ((PowerManager)getSystemService(POWER_SERVICE)).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "cerro:switch");
        wakeLock.acquire(15 * 60 * 1000L);
        new Thread(() -> {
            try { RootBackend.run(this, this::append, args); }
            catch (Exception error) { append(error.getMessage() == null ? error.toString() : error.getMessage()); }
            finally {
                if (wakeLock.isHeld()) wakeLock.release();
                busy.set(false); stopForeground(STOP_FOREGROUND_REMOVE); stopSelf();
            }
        }, "same-slot-switch").start();
        return START_NOT_STICKY; // Never automatically replay a partition-write intent.
    }
    @Override public IBinder onBind(Intent intent) { return null; }
}
