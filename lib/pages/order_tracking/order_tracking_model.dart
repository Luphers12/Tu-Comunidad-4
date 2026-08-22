import '/components/agent_card/agent_card_widget.dart';
import '/components/bottom_nav/bottom_nav_widget.dart';
import '/components/button/button_widget.dart';
import '/components/timeline_step/timeline_step_widget.dart';
import '/flutter_flow/flutter_flow_google_map.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/index.dart';
import 'order_tracking_widget.dart' show OrderTrackingWidget;
import 'package:flutter/material.dart';

class OrderTrackingModel extends FlutterFlowModel<OrderTrackingWidget> {
  ///  State fields for stateful widgets in this page.

  // State field(s) for Map Google Map widget.
  LatLng? mapGoogleMapsCenter;
  final mapGoogleMapsController = Completer<GoogleMapController>();
  // Model for TimelineStep.
  late TimelineStepModel timelineStepModel1;
  // Model for TimelineStep.
  late TimelineStepModel timelineStepModel2;
  // Model for TimelineStep.
  late TimelineStepModel timelineStepModel3;
  // Model for TimelineStep.
  late TimelineStepModel timelineStepModel4;
  // Model for AgentCard.
  late AgentCardModel agentCardModel;
  // Model for Button.
  late ButtonModel buttonModel1;
  // Model for Button.
  late ButtonModel buttonModel2;
  // Model for BottomNav.
  late BottomNavModel bottomNavModel;

  @override
  void initState(BuildContext context) {
    timelineStepModel1 = createModel(context, () => TimelineStepModel());
    timelineStepModel2 = createModel(context, () => TimelineStepModel());
    timelineStepModel3 = createModel(context, () => TimelineStepModel());
    timelineStepModel4 = createModel(context, () => TimelineStepModel());
    agentCardModel = createModel(context, () => AgentCardModel());
    buttonModel1 = createModel(context, () => ButtonModel());
    buttonModel2 = createModel(context, () => ButtonModel());
    bottomNavModel = createModel(context, () => BottomNavModel());
  }

  @override
  void dispose() {
    timelineStepModel1.dispose();
    timelineStepModel2.dispose();
    timelineStepModel3.dispose();
    timelineStepModel4.dispose();
    agentCardModel.dispose();
    buttonModel1.dispose();
    buttonModel2.dispose();
    bottomNavModel.dispose();
  }
}
