import '/components/button/button_widget.dart';
import '/components/role_card/role_card_widget.dart';
import '/components/text_field/text_field_widget.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/index.dart';
import 'registration_role_selection_widget.dart'
    show RegistrationRoleSelectionWidget;
import 'package:flutter/material.dart';

class RegistrationRoleSelectionModel
    extends FlutterFlowModel<RegistrationRoleSelectionWidget> {
  ///  State fields for stateful widgets in this page.

  // Model for TextField.
  late TextFieldModel textFieldModel1;
  // Model for TextField.
  late TextFieldModel textFieldModel2;
  // Model for TextField.
  late TextFieldModel textFieldModel3;
  // Model for RoleCard.
  late RoleCardModel roleCardModel1;
  // Model for RoleCard.
  late RoleCardModel roleCardModel2;
  // Model for RoleCard.
  late RoleCardModel roleCardModel3;
  // Model for Button.
  late ButtonModel buttonModel1;
  // Model for Button.
  late ButtonModel buttonModel2;

  @override
  void initState(BuildContext context) {
    textFieldModel1 = createModel(context, () => TextFieldModel());
    textFieldModel2 = createModel(context, () => TextFieldModel());
    textFieldModel3 = createModel(context, () => TextFieldModel());
    roleCardModel1 = createModel(context, () => RoleCardModel());
    roleCardModel2 = createModel(context, () => RoleCardModel());
    roleCardModel3 = createModel(context, () => RoleCardModel());
    buttonModel1 = createModel(context, () => ButtonModel());
    buttonModel2 = createModel(context, () => ButtonModel());
  }

  @override
  void dispose() {
    textFieldModel1.dispose();
    textFieldModel2.dispose();
    textFieldModel3.dispose();
    roleCardModel1.dispose();
    roleCardModel2.dispose();
    roleCardModel3.dispose();
    buttonModel1.dispose();
    buttonModel2.dispose();
  }
}
