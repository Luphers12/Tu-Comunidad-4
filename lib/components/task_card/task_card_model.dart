import '/components/button/button_widget.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'task_card_widget.dart' show TaskCardWidget;
import 'package:flutter/material.dart';

class TaskCardModel extends FlutterFlowModel<TaskCardWidget> {
  ///  State fields for stateful widgets in this component.

  // Model for Button.
  late ButtonModel buttonModel;

  @override
  void initState(BuildContext context) {
    buttonModel = createModel(context, () => ButtonModel());
  }

  @override
  void dispose() {
    buttonModel.dispose();
  }
}
