package com.tunetrail.push;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;

import androidx.annotation.NonNull;

import com.google.firebase.FirebaseApp;
import com.google.firebase.FirebaseOptions;
import com.google.firebase.messaging.FirebaseMessaging;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;

/** Firebase Cloud Messaging token + notification permission for Tunetrail. */
public class TunetrailPushPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware,
        PluginRegistry.RequestPermissionsResultListener {
    private static final int REQUEST = 4711;
    private MethodChannel channel;
    private Context context;
    private ActivityPluginBinding activity;
    private MethodChannel.Result pendingPermission;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        channel = new MethodChannel(binding.getBinaryMessenger(), "tunetrail/push");
        channel.setMethodCallHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        channel.setMethodCallHandler(null);
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "requestPermission":
                requestPermission(result);
                break;
            case "token":
                token(call, result);
                break;
            default:
                result.notImplemented();
        }
    }

    private void requestPermission(MethodChannel.Result result) {
        if (Build.VERSION.SDK_INT < 33
                || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            result.success(true);
            return;
        }
        Activity a = activity == null ? null : activity.getActivity();
        if (a == null || pendingPermission != null) {
            result.success(false);
            return;
        }
        pendingPermission = result;
        a.requestPermissions(new String[] {Manifest.permission.POST_NOTIFICATIONS}, REQUEST);
    }

    @Override
    public boolean onRequestPermissionsResult(int code, @NonNull String[] permissions, @NonNull int[] grants) {
        if (code != REQUEST || pendingPermission == null) return false;
        boolean ok = grants.length > 0 && grants[0] == PackageManager.PERMISSION_GRANTED;
        pendingPermission.success(ok);
        pendingPermission = null;
        return true;
    }

    private void token(MethodCall call, MethodChannel.Result result) {
        try {
            if (FirebaseApp.getApps(context).isEmpty()) {
                FirebaseOptions options = new FirebaseOptions.Builder()
                        .setApiKey((String) call.argument("apiKey"))
                        .setApplicationId((String) call.argument("appId"))
                        .setProjectId((String) call.argument("projectId"))
                        .setGcmSenderId((String) call.argument("senderId"))
                        .build();
                FirebaseApp.initializeApp(context, options);
            }
            FirebaseMessaging.getInstance().getToken().addOnCompleteListener(task -> {
                if (task.isSuccessful()) {
                    result.success(task.getResult());
                } else {
                    result.success(null);
                }
            });
        } catch (Exception e) {
            result.success(null);
        }
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding;
        binding.addRequestPermissionsResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        onDetachedFromActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        if (activity != null) activity.removeRequestPermissionsResultListener(this);
        activity = null;
    }
}
