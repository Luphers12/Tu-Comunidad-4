import '/components/radio/radio_widget.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'pickup_card_widget.dart' show PickupCardWidget;
import 'package:flutter/material.dart';

class PickupCardModel extends FlutterFlowModel<PickupCardWidget> {
  ///  State fields for stateful widgets in this component.

  // Model for Radio.
  late RadioModel radioModel;

  @override
  void initState(BuildContext context) {
    radioModel = createModel(context, () => RadioModel());
  }

  @override
  void dispose() {
    radioModel.dispose();
  }
}
