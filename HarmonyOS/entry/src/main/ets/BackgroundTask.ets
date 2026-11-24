import { common, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';

export async function startIndependentTask(context: common.Context,
  mode: backgroundTaskManager.BackgroundTaskMode, agent: WantAgent): Promise<number> {
  // The modes-array overload permits only one task per UIAbility.
  const request = new backgroundTaskManager.ContinuousTaskRequest();
  request.backgroundTaskModes = [mode];
  request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_NORMAL_NOTIFICATION];
  request.wantAgent = agent;
  request.combinedTaskNotification = false;
  const result = await backgroundTaskManager.startBackgroundRunning(context, request);
  const id = result.continuousTaskId ?? -1;
  if (id < 0) throw new Error('系统未分配后台任务');
  return id;
}
