import '/components/bottom_nav/bottom_nav_widget.dart';
import '/components/button/button_widget.dart';
import '/components/pickup_card2/pickup_card2_widget.dart';
import '/components/text_field/text_field_widget.dart';
import '/flutter_flow/flutter_flow_google_map.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/index.dart';
import 'pickup_points_map_widget.dart' show PickupPointsMapWidget;
import 'package:flutter/material.dart';

class PickupPointsMapModel extends FlutterFlowModel<PickupPointsMapWidget> {
  ///  State fields for stateful widgets in this page.

  // State field(s) for Map Google Map widget.
  LatLng? mapGoogleMapsCenter;
  final mapGoogleMapsController = Completer<GoogleMapController>();
  // Model for TextField.
  late TextFieldModel textFieldModel;
  // Model for PickupCard.
  late PickupCard2Model pickupCardModel1;
  // Model for PickupCard.
  late PickupCard2Model pickupCardModel2;
  // Model for PickupCard.
  late PickupCard2Model pickupCardModel3;
  // Model for Button.
  late ButtonModel buttonModel;
  // Model for BottomNav.
  late BottomNavModel bottomNavModel;

  @override
  void initState(BuildContext context) {
    textFieldModel = createModel(context, () => TextFieldModel());
    pickupCardModel1 = createModel(context, () => PickupCard2Model());
    pickupCardModel2 = createModel(context, () => PickupCard2Model());
    pickupCardModel3 = createModel(context, () => PickupCard2Model());
    buttonModel = createModel(context, () => ButtonModel());
    bottomNavModel = createModel(context, () => BottomNavModel());
  }

  @override
  void dispose() {
    textFieldModel.dispose();
    pickupCardModel1.dispose();
    pickupCardModel2.dispose();
    pickupCardModel3.dispose();
    buttonModel.dispose();
    bottomNavModel.dispose();
  }
}
