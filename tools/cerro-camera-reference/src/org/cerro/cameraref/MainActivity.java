/* SPDX-License-Identifier: Apache-2.0 */
package org.cerro.cameraref;

import android.app.Activity;
import android.os.*;
import android.content.*;
import android.graphics.*;
import android.hardware.camera2.*;
import android.hardware.camera2.params.*;
import android.media.*;
import android.util.*;
import android.view.*;
import android.widget.*;
import java.io.*;
import java.nio.*;
import java.lang.reflect.Array;
import java.util.*;
import org.json.*;

/** Read camera characteristics and bounded, ordinary Camera2 JPEG/metadata.
 * No vendor calibration, EEPROM, firmware or partition writes.
 */
public class MainActivity extends Activity {
 HandlerThread worker; Handler handler; CameraManager manager;
 CameraDevice device; CameraCaptureSession session; ImageReader reader, rawReader;
 Image pendingRaw; TotalCaptureResult rawResult; CameraCharacteristics characteristics;
 TextureView texture; TextView status; Surface preview;
 String cameraId; File folder; boolean shot=false; long frames=0;
 JSONObject inventory = new JSONObject();
 @Override public void onCreate(Bundle state) {
  super.onCreate(state);
  getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
  worker = new HandlerThread("CerroCameraRef");worker.start();handler=new Handler(worker.getLooper());
  manager=(CameraManager)getSystemService(CAMERA_SERVICE);
  cameraId=getIntent().getStringExtra("camera");if(cameraId==null)cameraId="0";
  folder=new File(getExternalFilesDir(null), "camera-"+cameraId+"-"+System.currentTimeMillis());folder.mkdirs();
  LinearLayout layout=new LinearLayout(this);layout.setOrientation(LinearLayout.VERTICAL);
  status=new TextView(this);status.setText("Cerro Camera2 采集 / 摄像头 "+cameraId);layout.addView(status);
  texture=new TextureView(this);layout.addView(texture,new LinearLayout.LayoutParams(-1,0,1));setContentView(layout);
  try { inventory(); } catch(Exception error){fail(error);}
  texture.setSurfaceTextureListener(new TextureView.SurfaceTextureListener(){
   public void onSurfaceTextureAvailable(SurfaceTexture st,int w,int h){handler.post(()->open());}
   public void onSurfaceTextureSizeChanged(SurfaceTexture st,int w,int h){}
   public boolean onSurfaceTextureDestroyed(SurfaceTexture st){return true;}
   public void onSurfaceTextureUpdated(SurfaceTexture st){}
  });
  handler.postDelayed(()->{save("timeout.json", "{\"closed_after_seconds\":20}");closeCamera();},20000);
 }
 Object value(Object x) throws JSONException {
  if(x==null)return JSONObject.NULL;
  if(x.getClass().isArray()){JSONArray a=new JSONArray();for(int i=0;i<Array.getLength(x);i++)a.put(value(Array.get(x,i)));return a;}
  if(x instanceof android.util.Rational)return x.toString();
  if(x instanceof Byte || x instanceof Short || x instanceof Integer || x instanceof Long || x instanceof Float || x instanceof Double || x instanceof Boolean || x instanceof String)return x;
  return x.toString();
 }
 void inventory() throws Exception {
  JSONArray cameras=new JSONArray();
  Set<String> ids=new LinkedHashSet<>(Arrays.asList(manager.getCameraIdList()));
  for(String id:new ArrayList<>(ids)) ids.addAll(manager.getCameraCharacteristics(id).getPhysicalCameraIds());
  for(String id:ids) {
   CameraCharacteristics c=manager.getCameraCharacteristics(id);JSONObject entry=new JSONObject();entry.put("id",id);
   JSONObject keys=new JSONObject();for(CameraCharacteristics.Key<?> k:c.getKeys())try{keys.put(k.getName(),value(c.get(k)));}catch(Exception e){keys.put(k.getName(),e.toString());}
   entry.put("characteristics",keys);entry.put("physicalIds",new JSONArray(c.getPhysicalCameraIds()));
   StreamConfigurationMap map=c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
   JSONObject formats=new JSONObject();if(map!=null)for(int f:map.getOutputFormats())formats.put(Integer.toString(f),value(map.getOutputSizes(f)));
   entry.put("outputSizes",formats);cameras.put(entry);
  }
  inventory.put("cameras",cameras);save("inventory.json",inventory.toString(2));
 }
 void save(String name,String text){try(FileOutputStream out=new FileOutputStream(new File(folder,name))){out.write(text.getBytes("UTF-8"));}catch(Exception e){Log.e("CerroCameraRef","save",e);}}
 void fail(Exception e){Log.e("CerroCameraRef","failed",e);save("error.txt",e.toString());runOnUiThread(()->status.setText("采集失败："+e));closeCamera();}
 Size choose(Size[] sizes,long max){Size best=null;for(Size s:sizes)if((long)s.getWidth()*s.getHeight()<=max && (best==null || (long)s.getWidth()*s.getHeight()>(long)best.getWidth()*best.getHeight()))best=s;return best==null?sizes[0]:best;}
 void open(){try{
  manager.openCamera(cameraId,new CameraDevice.StateCallback(){
   public void onOpened(CameraDevice d){device=d;configure();}
   public void onDisconnected(CameraDevice d){d.close();}
   public void onError(CameraDevice d,int error){fail(new Exception("cameraDevice error="+error));}
  },handler);
 }catch(Exception e){fail(e);}}
 void configure(){try{
  CameraCharacteristics c=manager.getCameraCharacteristics(cameraId);characteristics=c;StreamConfigurationMap map=c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
  Size p=choose(map.getOutputSizes(SurfaceTexture.class),1280L*720);Size j=choose(map.getOutputSizes(ImageFormat.JPEG),16000000);
  SurfaceTexture st=texture.getSurfaceTexture();st.setDefaultBufferSize(p.getWidth(),p.getHeight());preview=new Surface(st);
  reader=ImageReader.newInstance(j.getWidth(),j.getHeight(),ImageFormat.JPEG,2);
  reader.setOnImageAvailableListener(r->{try(Image im=r.acquireNextImage()){
   ByteBuffer b=im.getPlanes()[0].getBuffer();byte[] bytes=new byte[b.remaining()];b.get(bytes);
   try(FileOutputStream out=new FileOutputStream(new File(folder,"capture.jpg"))){out.write(bytes);}
   Log.i("CerroCameraRef","JPEG_SAVED camera="+cameraId+" size="+im.getWidth()+"x"+im.getHeight());
   runOnUiThread(()->status.setText("摄像头 "+cameraId+" 已拍照并保存参数"));
  }catch(Exception e){fail(e);}},handler);
  List<Surface> surfaces=new ArrayList<>(Arrays.asList(preview,reader.getSurface()));
  if(getIntent().getBooleanExtra("raw",false)) {
   Size[] rawSizes=map.getOutputSizes(ImageFormat.RAW_SENSOR);
   if(rawSizes==null || rawSizes.length==0)throw new Exception("RAW_SENSOR unavailable");
   Size raw=choose(rawSizes,20000000);
   rawReader=ImageReader.newInstance(raw.getWidth(),raw.getHeight(),ImageFormat.RAW_SENSOR,2);
   rawReader.setOnImageAvailableListener(r->{pendingRaw=r.acquireNextImage();writeRaw();},handler);
   surfaces.add(rawReader.getSurface());
  }
  session=null;
  device.createCaptureSession(surfaces,new CameraCaptureSession.StateCallback(){
   public void onConfigured(CameraCaptureSession s){session=s;startPreview();}
   public void onConfigureFailed(CameraCaptureSession s){fail(new Exception("session configure failed"));}
  },handler);
 }catch(Exception e){fail(e);}}
 void settings(CaptureRequest.Builder b) throws Exception {
  b.set(CaptureRequest.CONTROL_MODE,CameraMetadata.CONTROL_MODE_AUTO);
  b.set(CaptureRequest.CONTROL_AF_MODE,CameraMetadata.CONTROL_AF_MODE_CONTINUOUS_PICTURE);
  b.set(CaptureRequest.CONTROL_AE_MODE,CameraMetadata.CONTROL_AE_MODE_ON);
  if(getIntent().hasExtra("ev"))b.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION,getIntent().getIntExtra("ev",0));
  if(getIntent().hasExtra("exposureUs")){
   b.set(CaptureRequest.CONTROL_AE_MODE,CameraMetadata.CONTROL_AE_MODE_OFF);
   b.set(CaptureRequest.SENSOR_EXPOSURE_TIME,getIntent().getLongExtra("exposureUs",10000)*1000);
   b.set(CaptureRequest.SENSOR_SENSITIVITY,getIntent().getIntExtra("iso",100));
  }
  if(getIntent().hasExtra("zoom"))b.set(CaptureRequest.CONTROL_ZOOM_RATIO,getIntent().getFloatExtra("zoom",1));
 }
 void dump(TotalCaptureResult result,String name){try{
  JSONObject j=new JSONObject();for(CaptureResult.Key<?> k:result.getKeys())try{j.put(k.getName(),value(result.get(k)));}catch(Exception e){}
  save(name,j.toString(2));
 }catch(Exception e){fail(e);}}
 void startPreview(){try{
  CaptureRequest.Builder b=device.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW);b.addTarget(preview);settings(b);
  session.setRepeatingRequest(b.build(),new CameraCaptureSession.CaptureCallback(){public void onCaptureCompleted(CameraCaptureSession s,CaptureRequest q,TotalCaptureResult r){if(++frames%30==0)dump(r,"preview-result.json");}},handler);
  handler.postDelayed(()->capture(),4000);
 }catch(Exception e){fail(e);}}
 void capture(){if(shot || session==null)return;shot=true;try{
  CaptureRequest.Builder b=device.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE);b.addTarget(reader.getSurface());if(rawReader!=null)b.addTarget(rawReader.getSurface());settings(b);
  b.set(CaptureRequest.JPEG_QUALITY,(byte)95);b.set(CaptureRequest.JPEG_ORIENTATION,90);
  session.capture(b.build(),new CameraCaptureSession.CaptureCallback(){
   public void onCaptureCompleted(CameraCaptureSession s,CaptureRequest q,TotalCaptureResult r){dump(r,"capture-result.json");rawResult=r;writeRaw();handler.postDelayed(()->closeCamera(),1800);}
   public void onCaptureFailed(CameraCaptureSession s,CaptureRequest q,CaptureFailure f){fail(new Exception("capture failure="+f.getReason()));}
  },handler);
 }catch(Exception e){fail(e);}}
 void writeRaw(){if(pendingRaw==null || rawResult==null)return;try {
  Image im=pendingRaw;pendingRaw=null;
  try {
   try(DngCreator dng=new DngCreator(characteristics,rawResult);FileOutputStream out=new FileOutputStream(new File(folder,"capture.dng"))){dng.writeImage(out,im);}
   ByteBuffer b=im.getPlanes()[0].getBuffer();byte[] bytes=new byte[b.remaining()];b.get(bytes);
   try(FileOutputStream out=new FileOutputStream(new File(folder,"capture-raw16.bin"))){out.write(bytes);}
   save("raw-layout.json",new JSONObject().put("width",im.getWidth()).put("height",im.getHeight()).put("rowStride",im.getPlanes()[0].getRowStride()).put("pixelStride",im.getPlanes()[0].getPixelStride()).toString(2));
   Log.i("CerroCameraRef","RAW_SAVED camera="+cameraId+" size="+im.getWidth()+"x"+im.getHeight());
  }finally{im.close();}
 }catch(Exception e){fail(e);}}
 void closeCamera(){if(pendingRaw!=null){pendingRaw.close();pendingRaw=null;}if(rawReader!=null){rawReader.close();rawReader=null;}if(session!=null){session.close();session=null;}if(device!=null){device.close();device=null;}if(reader!=null){reader.close();reader=null;}if(preview!=null){preview.release();preview=null;}}
 @Override public void onDestroy(){handler.post(()->closeCamera());worker.quitSafely();super.onDestroy();}
}
