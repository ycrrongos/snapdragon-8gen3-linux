package org.cerro.switchos;

import android.content.Context;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.function.Consumer;

final class RootBackend {
    static String quote(String value) {
        return "'" + value.replace("'", "'\\''") + "'";
    }
    static synchronized File script(Context context) throws IOException {
        File output = new File(context.getFilesDir(), "same-slot-backend.sh");
        File temporary = new File(context.getFilesDir(), "same-slot-backend.new");
        try (InputStream input = context.getAssets().open("switch-backend.sh");
             FileOutputStream stream = new FileOutputStream(temporary)) {
            byte[] block = new byte[16384];
            int count;
            while ((count = input.read(block)) != -1) stream.write(block, 0, count);
            stream.getFD().sync();
        }
        if (!temporary.renameTo(output)) throw new IOException("无法准备内置切换后端");
        return output;
    }
    static String run(Context context, Consumer<String> progress, String... arguments) throws Exception {
        StringBuilder command = new StringBuilder("/system/bin/sh ").append(quote(script(context).getAbsolutePath()));
        for (String argument : arguments) command.append(' ').append(quote(argument));
        Process process = new ProcessBuilder("su", "-c", command.toString()).redirectErrorStream(true).start();
        StringBuilder output = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                output.append(line).append('\n');
                if (progress != null) progress.accept(line);
            }
        }
        int result = process.waitFor();
        if (result != 0) throw new IOException(output + "\n操作停止（退出码 " + result + "）；没有继续重启。");
        return output.toString().trim();
    }
}
