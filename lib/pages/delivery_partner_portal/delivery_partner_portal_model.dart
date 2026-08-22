import '/components/bottom_nav/bottom_nav_widget.dart';
import '/components/button/button_widget.dart';
import '/components/route_stat/route_stat_widget.dart';
import '/components/task_card/task_card_widget.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/index.dart';
import 'delivery_partner_portal_widget.dart' show DeliveryPartnerPortalWidget;
import 'package:flutter/material.dart';

class DeliveryPartnerPortalModel
    extends FlutterFlowModel<DeliveryPartnerPortalWidget> {
  ///  State fields for stateful widgets in this page.

  // Model for RouteStat.
  late RouteStatModel routeStatModel1;
  // Model for RouteStat.
  late RouteStatModel routeStatModel2;
  // Model for Button.
  late ButtonModel buttonModel;
  // Model for TaskCard.
  late TaskCardModel taskCardModel1;
  // Model for TaskCard.
  late TaskCardModel taskCardModel2;
  // Model for TaskCard.
  late TaskCardModel taskCardModel3;
  // Model for TaskCard.
  late TaskCardModel taskCardModel4;
  // Model for BottomNav.
  late BottomNavModel bottomNavModel;

  @override
  void initState(BuildContext context) {
    routeStatModel1 = createModel(context, () => RouteStatModel());
    routeStatModel2 = createModel(context, () => RouteStatModel());
    buttonModel = createModel(context, () => ButtonModel());
    taskCardModel1 = createModel(context, () => TaskCardModel());
    taskCardModel2 = createModel(context, () => TaskCardModel());
    taskCardModel3 = createModel(context, () => TaskCardModel());
    taskCardModel4 = createModel(context, () => TaskCardModel());
    bottomNavModel = createModel(context, () => BottomNavModel());
  }

  @override
  void dispose() {
    routeStatModel1.dispose();
    routeStatModel2.dispose();
    buttonModel.dispose();
    taskCardModel1.dispose();
    taskCardModel2.dispose();
    taskCardModel3.dispose();
    taskCardModel4.dispose();
    bottomNavModel.dispose();
  }
}
