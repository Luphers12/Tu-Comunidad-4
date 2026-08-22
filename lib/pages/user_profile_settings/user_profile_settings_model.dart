import '/components/bottom_nav/bottom_nav_widget.dart';
import '/components/button/button_widget.dart';
import '/components/settings_row/settings_row_widget.dart';
import '/components/stat_pill/stat_pill_widget.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'user_profile_settings_widget.dart' show UserProfileSettingsWidget;
import 'package:flutter/material.dart';

class UserProfileSettingsModel
    extends FlutterFlowModel<UserProfileSettingsWidget> {
  ///  State fields for stateful widgets in this page.

  // Model for StatPill.
  late StatPillModel statPillModel1;
  // Model for StatPill.
  late StatPillModel statPillModel2;
  // Model for SettingsRow.
  late SettingsRowModel settingsRowModel1;
  // Model for SettingsRow.
  late SettingsRowModel settingsRowModel2;
  // Model for SettingsRow.
  late SettingsRowModel settingsRowModel3;
  // Model for SettingsRow.
  late SettingsRowModel settingsRowModel4;
  // Model for SettingsRow.
  late SettingsRowModel settingsRowModel5;
  // Model for SettingsRow.
  late SettingsRowModel settingsRowModel6;
  // Model for Button.
  late ButtonModel buttonModel;
  // Model for BottomNav.
  late BottomNavModel bottomNavModel;

  @override
  void initState(BuildContext context) {
    statPillModel1 = createModel(context, () => StatPillModel());
    statPillModel2 = createModel(context, () => StatPillModel());
    settingsRowModel1 = createModel(context, () => SettingsRowModel());
    settingsRowModel2 = createModel(context, () => SettingsRowModel());
    settingsRowModel3 = createModel(context, () => SettingsRowModel());
    settingsRowModel4 = createModel(context, () => SettingsRowModel());
    settingsRowModel5 = createModel(context, () => SettingsRowModel());
    settingsRowModel6 = createModel(context, () => SettingsRowModel());
    buttonModel = createModel(context, () => ButtonModel());
    bottomNavModel = createModel(context, () => BottomNavModel());
  }

  @override
  void dispose() {
    statPillModel1.dispose();
    statPillModel2.dispose();
    settingsRowModel1.dispose();
    settingsRowModel2.dispose();
    settingsRowModel3.dispose();
    settingsRowModel4.dispose();
    settingsRowModel5.dispose();
    settingsRowModel6.dispose();
    buttonModel.dispose();
    bottomNavModel.dispose();
  }
}
