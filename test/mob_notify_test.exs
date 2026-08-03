defmodule MobNotifyTest do
  use ExUnit.Case, async: true

  alias MobDev.Plugin.{Manifest, Validator, Verify}

  @plugin_dir Path.expand("..", __DIR__)
  @contract Code.eval_file(Path.join(__DIR__, "fixtures/push_contract.exs")) |> elem(0)

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "loads and validates clean (round-trips)", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "classifies as tier 1 (NIF plugin)", %{manifest: m} do
      assert Manifest.tier(m) == 1
    end

    test "passes the full pre-publish validator", %{manifest: m} do
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "ships a current version signature for the manifest and referenced native sources", %{
      manifest: m
    } do
      assert {:ok, 2} = Verify.verify_plugin_with_version(@plugin_dir, m)
    end

    @tag :tmp_dir
    test "rejects a signature after the real Kotlin bridge is changed", %{tmp_dir: tmp_dir} do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      assert_signed_source_tamper_rejected!(tmp_dir, manifest.android.bridge_kt)
    end

    @tag :tmp_dir
    test "rejects a signature after the real Objective-C NIF source is changed", %{
      tmp_dir: tmp_dir
    } do
      assert_signed_source_tamper_rejected!(tmp_dir, "priv/native/ios/mob_notify_nif.m")
    end

    @tag :tmp_dir
    test "rejects a signature after the real Zig NIF source is changed", %{tmp_dir: tmp_dir} do
      assert_signed_source_tamper_rejected!(tmp_dir, "priv/native/jni/mob_notify_nif.zig")
    end

    test "declares the cross-platform NIF pattern: one module, both platforms",
         %{manifest: m} do
      assert [ios, android] = m.nifs
      assert ios.module == :mob_notify_nif and ios.platform == :ios and ios.lang == :objc
      assert android.module == :mob_notify_nif and android.platform == :android
      assert android.lang == :zig
    end

    test "declares POST_NOTIFICATIONS + SCHEDULE_EXACT_ALARM + RECEIVE_BOOT_COMPLETED + the FCM client dep",
         %{manifest: m} do
      assert "android.permission.POST_NOTIFICATIONS" in m.android.permissions
      assert "android.permission.SCHEDULE_EXACT_ALARM" in m.android.permissions
      assert "android.permission.RECEIVE_BOOT_COMPLETED" in m.android.permissions
      assert Enum.any?(m.android.gradle_deps, &(&1 =~ "firebase-messaging"))
    end

    test "declares all five host requirements (FCM service, google-services, AppDelegate token, receiver, boot receiver)",
         %{manifest: m} do
      assert length(m.host_requirements) == 5
      assert Enum.any?(m.host_requirements, &(&1 =~ "MobFirebaseService"))
      assert Enum.any?(m.host_requirements, &(&1 =~ "google-services"))
      assert Enum.any?(m.host_requirements, &(&1 =~ "mob_send_push_token"))
      assert Enum.any?(m.host_requirements, &(&1 =~ "NotificationReceiver"))

      assert Enum.any?(
               m.host_requirements,
               &(&1 =~ "MobNotifyBootReceiver" and &1 =~ "BOOT_COMPLETED")
             )
    end

    test "ships the Kotlin bridge the manifest references", %{manifest: m} do
      assert m.android.bridge_class == "io.mob.notify.MobNotifyBridge"
      assert File.exists?(Path.join(@plugin_dir, m.android.bridge_kt))
    end
  end

  describe "android exact-alarm guard (regression)" do
    # Android 12+ gates exact alarms behind SCHEDULE_EXACT_ALARM special access;
    # calling setExact* without it throws and the whole schedule silently failed.
    # The arm path must guard on canScheduleExactAlarms() and fall back to an
    # inexact alarm. The guard lives in the shared MobNotifySchedules object
    # (used by both the bridge and the boot receiver), declared in the same
    # bridge_kt file. Source-level because JNI/AlarmManager isn't exercisable
    # from mix test (see CLAUDE.md).
    setup do
      {:ok, m} = Manifest.load(@plugin_dir)
      %{src: File.read!(Path.join(@plugin_dir, m.android.bridge_kt))}
    end

    test "guards setExact with canScheduleExactAlarms", %{src: src} do
      assert src =~ "canScheduleExactAlarms"
    end

    test "has an inexact fallback so a notification still fires without the grant", %{src: src} do
      assert src =~ "setAndAllowWhileIdle"
    end
  end

  describe "android boot re-arm (RECEIVE_BOOT_COMPLETED)" do
    # AlarmManager alarms are wiped on reboot, so scheduled notifications vanish.
    # notify_schedule persists the schedule and MobNotifyBootReceiver re-arms
    # still-future entries on ACTION_BOOT_COMPLETED. The shared logic lives in the
    # MobNotifySchedules object so the bridge and the receiver arm identically.
    # Everything is declared in the one bridge_kt file (mob_dev copies + signs
    # exactly that path — sibling .kt files wouldn't be compiled/signed). Source-
    # level because JNI/AlarmManager isn't exercisable from mix test.
    setup do
      {:ok, m} = Manifest.load(@plugin_dir)
      %{src: File.read!(Path.join(@plugin_dir, m.android.bridge_kt))}
    end

    test "ships the boot receiver as a BroadcastReceiver in io.mob.notify", %{src: src} do
      assert src =~ "package io.mob.notify"
      assert src =~ "class MobNotifyBootReceiver"
      assert src =~ "BroadcastReceiver"
    end

    test "the boot receiver re-arms on BOOT_COMPLETED", %{src: src} do
      assert src =~ "ACTION_BOOT_COMPLETED"
      assert src =~ "rearmAll"
    end

    test "notify_schedule persists the schedule (so a reboot can re-arm)", %{src: src} do
      # The bridge delegates persistence to the shared object, which writes the
      # schedule (keyed by id) to SharedPreferences.
      assert src =~ "MobNotifySchedules.schedule"
      assert src =~ "getSharedPreferences"
      assert src =~ "trigger_at_ms"
    end

    test "the shared object is used by both the bridge and the boot path", %{src: src} do
      assert src =~ "object MobNotifySchedules"
      # The re-arm reuses the same exact-alarm guard + inexact fallback.
      assert src =~ "canScheduleExactAlarms"
      assert src =~ "setAndAllowWhileIdle"
      # Past-due entries are skipped on re-arm.
      assert src =~ "System.currentTimeMillis"
      # The boot receiver calls into the shared object.
      assert src =~ "MobNotifySchedules.rearmAll"
    end
  end

  describe "android push-token registration delivery" do
    # Firebase APIs and JNI are unavailable to host-side ExUnit, so pin the
    # plugin-owned Kotlin/Zig contract that the native host build compiles.
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)

      %{
        kotlin: File.read!(Path.join(@plugin_dir, manifest.android.bridge_kt)),
        zig: File.read!(Path.join(@plugin_dir, "priv/native/jni/mob_notify_nif.zig"))
      }
    end

    test "uses a plugin-owned error thunk with no host-package reference", %{kotlin: kotlin} do
      assert kotlin =~
               "external fun nativeDeliverNotifyPushTokenError(pid: Long, reason: String)"

      assert kotlin =~ "nativeDeliverNotifyPushTokenError(pid, reason)"
      refute kotlin =~ "com.example."
      refute kotlin =~ "MobBridge.nativeDeliverAtom3"
    end

    test "delivers valid cached tokens and reports blank cached tokens", %{kotlin: kotlin} do
      assert kotlin =~ "if (cached.isNotBlank())"
      assert kotlin =~ "nativeDeliverNotifyPushToken(pid, cached)"
      assert kotlin =~ ~s|deliverPushTokenError(pid, "cached_token_blank")|
    end

    test "delivers valid Firebase tokens and reports blank or failed fetches", %{kotlin: kotlin} do
      assert kotlin =~ "if (!token.isNullOrBlank())"
      assert kotlin =~ "nativeDeliverNotifyPushToken(pid, token)"
      assert kotlin =~ ~s|deliverPushTokenError(pid, "firebase_token_blank")|
      assert kotlin =~ "task.exception?.javaClass?.simpleName"
      assert kotlin =~ ~s("firebase_token_fetch_failed")
      assert kotlin =~ "deliverPushTokenError(pid, reason)"
    end

    test "the JNI error thunk sends the exact three-element BEAM message", %{zig: zig} do
      assert [thunk] =
               Regex.run(
                 ~r/export fn Java_io_mob_notify_MobNotifyBridge_nativeDeliverNotifyPushTokenError\([\s\S]*?\n\}/,
                 zig
               )

      assert thunk =~ ~s|erts.atom(env, "push_token_error")|
      assert thunk =~ ~s|erts.atom(env, "android")|
      assert thunk =~ "erts.enif_make_binary(env, &reason_bin)"
      assert thunk =~ "erts.enif_send(null, &pid, env, msg)"

      assert Regex.match?(
               ~r/push_token_error[\s\S]*android[\s\S]*enif_make_binary/,
               thunk
             )
    end
  end

  describe "NIF stub agreement" do
    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the manifest NIF module is the shipped .erl stub and loads on the host" do
      assert Code.ensure_loaded?(:mob_notify_nif)
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every NIF the public API calls is exported by the stub at the right arity" do
      exports = :mob_notify_nif.module_info(:exports)

      for fa <- [notify_schedule: 1, notify_cancel: 1, notify_register_push: 0] do
        assert fa in exports, "#{inspect(fa)} missing from mob_notify_nif exports"
      end
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "host (no native linked) falls back to nif_not_loaded, not a load crash" do
      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        :mob_notify_nif.notify_register_push()
      end
    end
  end

  describe "schedule_opts/1 (parity with old Mob.Notify)" do
    test "builds the exact JSON shape core's nif_notify_schedule consumes" do
      opts = MobNotify.schedule_opts(id: "r1", title: "T", body: "B", delay_seconds: 60)

      assert %{"id" => "r1", "title" => "T", "body" => "B", "data" => %{}} = opts
      assert is_integer(opts["trigger_at"])
      assert opts["trigger_at"] > DateTime.to_unix(DateTime.utc_now())
    end

    test "at: takes precedence and data keys are stringified" do
      at = ~U[2030-01-01 00:00:00Z]
      opts = MobNotify.schedule_opts(id: "r", title: "t", body: "b", at: at, data: %{screen: "x"})

      assert opts["trigger_at"] == DateTime.to_unix(at)
      assert opts["data"] == %{"screen" => "x"}
    end

    test "missing required keys raise" do
      assert_raise KeyError, fn -> MobNotify.schedule_opts(title: "t", body: "b") end
    end
  end

  describe "push contract (vendored fixture, shared with mob_push)" do
    test "registration message shapes are what core's native side delivers" do
      assert [{:push_token, :ios, ios_tok}, {:push_token, :android, android_tok}] =
               @contract.push_token_messages

      assert is_binary(ios_tok) and is_binary(android_tok)
    end

    test "the Android push envelope decodes to the documented handle_info shape" do
      decoded = @contract.mob_notification_decoded

      assert {:notification, promised} = @contract.device_push_notification
      assert decoded["title"] == promised.title
      assert decoded["body"] == promised.body
      assert decoded["source"] == "push" and promised.source == :push
      assert decoded["data"] == promised.data
    end

    test "the known iOS source-drift is still open (delete this when Stage 1b/2 fixes it)" do
      # ios/mob_nif.m's delegate hardcodes source "local" + omits title/body;
      # the contract documents the Android envelope as the promise. When the
      # native pass aligns iOS, flip the fixture's :known_drift to :resolved
      # in BOTH repos and update device_local/push shapes accordingly.
      assert @contract.known_drift == :ios_delegate_hardcodes_local_source
    end
  end

  describe "public API surface (extraction parity with old Mob.Notify)" do
    test "exports the full extracted surface" do
      exports = MobNotify.__info__(:functions)

      for fa <- [schedule: 2, cancel: 2, register_push: 1, schedule_opts: 1] do
        assert fa in exports, "#{inspect(fa)} missing from MobNotify"
      end
    end
  end

  defp assert_signed_source_tamper_rejected!(tmp_dir, relative_path) do
    File.cp_r!(Path.join(@plugin_dir, "priv"), Path.join(tmp_dir, "priv"))
    {:ok, manifest} = Manifest.load(tmp_dir)

    assert {:ok, 2} = Verify.verify_plugin_with_version(tmp_dir, manifest)

    source_path = Path.join(tmp_dir, relative_path)
    assert File.regular?(source_path)
    File.write!(source_path, "\n// signature regression tamper\n", [:append])

    assert {:error, :invalid_signature} =
             Verify.verify_plugin_with_version(tmp_dir, manifest)
  end
end
