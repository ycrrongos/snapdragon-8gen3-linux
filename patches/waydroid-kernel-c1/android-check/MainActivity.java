package org.cerro.waydroidcheck;
import android.app.Activity;
import android.os.Bundle;
import android.os.Process;
import android.media.AudioManager;
import android.media.ToneGenerator;
import android.widget.*;
import java.net.URL;
import javax.net.ssl.HttpsURLConnection;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import org.json.JSONObject;

/** Disposable real app-UID TLS/audio-submission check; no root or device data. */
public class MainActivity extends Activity {
 private TextView results;
 private ToneGenerator tone;
 private final JSONObject report=new JSONObject();
 @Override public void onCreate(Bundle state) {
  super.onCreate(state);
  LinearLayout box=new LinearLayout(this);box.setOrientation(1);box.setPadding(32,32,32,32);
  TextView title=new TextView(this);title.setText("Waydroid application check");title.setTextSize(28);box.addView(title);
  results=new TextView(this);results.setTextSize(20);results.setText("Testing HTTPS under ordinary app UID…");box.addView(results);
  Button button=new Button(this);button.setText("Play short test tone");box.addView(button);
  button.setOnClickListener(v->{
   if(tone==null)tone=new ToneGenerator(AudioManager.STREAM_MUSIC,30);
   boolean submitted=tone.startTone(ToneGenerator.TONE_PROP_BEEP,1500);
   try {report.put("audio_submitted",submitted);save();}catch(Exception e){results.append("\n"+e.getClass().getSimpleName());}
  });
  setContentView(box);
  new Thread(()->{
   try {
    report.put("uid",Process.myUid());
    for(String domain:new String[]{"example.com","www.baidu.com"}) {
     HttpsURLConnection connection=(HttpsURLConnection)new URL("https://"+domain+"/").openConnection();
     connection.setConnectTimeout(12000);connection.setReadTimeout(12000);connection.setInstanceFollowRedirects(true);
     try {report.put(domain,connection.getResponseCode());} finally {connection.disconnect();}
    }
   } catch(Exception error) {try {report.put("error",error.getClass().getSimpleName()+": "+error.getMessage());}catch(Exception ignored){}}
   runOnUiThread(()->{try {save();}catch(Exception e){results.setText(e.toString());}});
  }).start();
 }
 private void save() throws Exception {
  String text=report.toString(2);results.setText(text);
  Files.write(new File(getFilesDir(),"report.json").toPath(),text.getBytes(StandardCharsets.UTF_8));
 }
 @Override protected void onDestroy(){if(tone!=null)tone.release();super.onDestroy();}
}
