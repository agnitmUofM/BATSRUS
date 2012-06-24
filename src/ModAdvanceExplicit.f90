!^CFG COPYRIGHT UM
!===========================================================================

subroutine advance_expl(DoCalcTimestep, iStageMax)

  use ModMain
  use ModFaceBoundary, ONLY: set_face_boundary
  use ModFaceFlux,   ONLY: calc_face_flux
  use ModFaceValue,  ONLY: calc_face_value
  use ModAdvance,    ONLY: UseUpdateCheck, DoFixAxis, &
       DoCalcElectricField
  use ModB0,         ONLY: set_b0_face
  use ModParallel,   ONLY: neiLev
  use ModGeometry,   ONLY: Body_BLK
  use ModBlockData,  ONLY: set_block_data
  use ModImplicit,   ONLY: UsePartImplicit           !^CFG IF IMPLICIT
  use ModPhysics,    ONLY: No2Si_V, UnitT_
  use ModCalcSource, ONLY: calc_source
  use ModConserveFlux, ONLY: save_cons_flux, apply_cons_flux, &
       nCorrectedFaceValues, CorrectedFlux_VXB, &
       CorrectedFlux_VYB, CorrectedFlux_VZB
  use ModCoronalHeating, ONLY: get_coronal_heat_factor, UseUnsignedFluxModel
  use ModMessagePass, ONLY: exchange_messages
  use ModTimeStepControl, ONLY: calc_timestep
  use BATL_lib, ONLY: message_pass_face, IsAnyAxis

  implicit none

  logical, intent(in) :: DoCalcTimestep
  integer, intent(in) :: iStageMax ! advance only part way
  integer :: iStage, iBlock

  character (len=*), parameter :: NameSub = 'advance_expl'

  logical :: DoTest, DoTestMe
  !-------------------------------------------------------------------------
  call set_oktest(NameSub, DoTest, DoTestMe)

  !\
  ! Perform multi-stage update of solution for this time (iteration) step
  !/
  if(UsePartImplicit)call timing_start('advance_expl') !^CFG IF IMPLICIT

  if(UseBody2 .and. UseOrbit) call update_secondbody  !^CFG IF SECONDBODY

  STAGELOOP: do iStage = 1, nStage

     if(DoTestMe) write(*,*)NameSub,' starting stage=',iStage

     ! If heating model depends on global B topology, update here
     if(UseUnsignedFluxModel) call get_coronal_heat_factor

     call barrier_mpi2('expl1')

     do globalBLK = 1, nBlock
        if (unusedBLK(globalBLK)) CYCLE
        if(all(neiLev(:,globalBLK)/=1)) CYCLE
        ! Calculate interface values for L/R states of each 
        ! fine grid cell face at block edges with resolution changes
        !   and apply BCs for interface states as needed.
        call set_b0_face(globalBLK)
        call timing_start('calc_face_bfo')
        call calc_face_value(.true.,GlobalBlk)
        call timing_stop('calc_face_bfo')

        if(body_BLK(globalBLK))call set_face_boundary(globalBLK, Time_Simulation, .true.)

        ! Compute interface fluxes for each fine grid cell face at
        ! block edges with resolution changes.

        call timing_start('calc_fluxes_bfo')
        call calc_face_flux(.true., GlobalBlk)
        call timing_stop('calc_fluxes_bfo')

        ! Save conservative flux correction for this solution block
        call save_cons_flux(GlobalBlk)
        
     end do

     if(DoTestMe)write(*,*)NameSub,' done res change only'

     ! Message pass conservative flux corrections.
     call timing_start('send_cons_flux')
     call message_pass_face(nCorrectedFaceValues, CorrectedFlux_VXB, &
          CorrectedFlux_VYB, CorrectedFlux_VZB, DoSubtractIn=.false.)

     call timing_stop('send_cons_flux')

     if(DoTestMe)write(*,*)NameSub,' done message pass'

     ! Multi-block solution update.
     do globalBLK = 1, nBlock

        if (unusedBLK(globalBLK)) CYCLE

        ! Calculate interface values for L/R states of each face
        !   and apply BCs for interface states as needed.
        call set_b0_face(globalBLK)
        call timing_start('calc_facevalues')
        call calc_face_value(.false., GlobalBlk)
        call timing_stop('calc_facevalues')

        if(body_BLK(globalBLK)) &
             call set_face_boundary(globalBLK, Time_Simulation,.false.)

        ! Compute interface fluxes for each cell.
        call timing_start('calc_fluxes')
        call calc_face_flux(.false., GlobalBlk)
        call timing_stop('calc_fluxes')

        ! Enforce flux conservation by applying corrected fluxes
        ! to each coarse grid cell face at block edges with 
        ! resolution changes.
        call apply_cons_flux(GlobalBlk)

        ! Compute source terms for each cell.
        call timing_start('calc_sources')
        call calc_source(GlobalBlk)
        call timing_stop('calc_sources')

        ! Calculate time step (both local and global
        ! for the block) used in multi-stage update
        ! for steady state calculations.
        if (.not.time_accurate .and. iStage == 1 &
             .and. DoCalcTimestep) call calc_timestep(GlobalBlk)

        ! Update solution state in each cell.
        call timing_start('update_states')
        call update_states(iStage,globalBLK)
        call timing_stop('update_states')

        if(DoCalcElectricField .and. iStage == nStage) &
             call calc_electric_field(globalBLK)

        if(UseConstrainB .and. iStage==nStage)then    !^CFG IF CONSTRAINB BEGIN
           call timing_start('constrain_B')
           call get_VxB(GlobalBlk)
           call bound_VxB(GlobalBlk)
           call timing_stop('constrain_B')
        end if                                        !^CFG END CONSTRAINB

        ! Calculate time step (both local and global
        ! for the block) used in multi-stage update
        ! for time accurate calculations.
        if (time_accurate .and. iStage == nStage .and. DoCalcTimestep) &
             call calc_timestep(GlobalBlk)

     end do ! Multi-block solution update loop.

     if(DoTestMe)write(*,*)NameSub,' done update blocks'

     call barrier_mpi2('expl2')

     if(IsAnyAxis .and. DoFixAxis) call fix_axis_cells

     ! Check for allowable update percentage change.
     if(UseUpdateCheck)then
        call timing_start('update_check')
        call update_check(iStage)
        call timing_stop('update_check')

        if(DoTestMe)write(*,*)NameSub,' done update check'
     end if

     if(UseConstrainB .and. iStage==nStage)then    !^CFG IF CONSTRAINB BEGIN
        call timing_start('constrain_B')
        ! Correct for consistency at resolution changes
        !call correct_VxB

        ! Update face centered and cell centered magnetic fields
        do iBlock = 1, nBlock
           if(unusedBLK(iBlock))CYCLE
           call constrain_B(iBlock)
           call Bface2Bcenter(iBlock)
        end do
        call timing_stop('constrain_B')
        if(DoTestMe)write(*,*)NameSub,' done constrain B'
     end if                                        !^CFG END CONSTRAINB

     if(DoCalcTimeStep) &
          Time_Simulation = Time_Simulation + Dt*No2Si_V(UnitT_)/nStage

     if(iStage<nStage)call exchange_messages

     if(DoTestMe)write(*,*)NameSub,' finished stage=',istage

     ! exit if exceeded requested maximum stage limit
     if ((iStageMax >= 0) .and. (iStage >= iStageMax)) EXIT STAGELOOP

  end do STAGELOOP  ! Multi-stage solution update loop.

  do iBlock = 1, nBlock
     if(.not.UnusedBlk(iBlock)) call set_block_data(iBlock)
  end do

  if(UsePartImplicit)call timing_stop('advance_expl') !^CFG IF IMPLICIT

  if(DoTestMe)write(*,*)NameSub,' finished'

end subroutine advance_expl

!^CFG IF SECONDBODY BEGIN
!===========================================================================

subroutine update_secondbody
  use ModMain,     ONLY: time_simulation,globalBLK,nBlock
  use ModConst,    ONLY: cTwoPi
  use ModPhysics,  ONLY: xBody2,yBody2,OrbitPeriod,PhaseBody2,DistanceBody2
  use ModMessagePass, ONLY: exchange_messages

  implicit none
  !-------------------------------------------------------------------------

  ! Update second body coordinates
  xBody2 = DistanceBody2*cos(cTwoPi*Time_Simulation/OrbitPeriod+PhaseBody2)
  yBody2 = DistanceBody2*sin(cTwoPi*Time_Simulation/OrbitPeriod+PhaseBody2)

  do globalBLK = 1, nBlock
     call set_boundary_cells(globalBLK)
     call fix_block_geometry(globalBLK)
  end do
  
  ! call set_body_flag ! OLDAMR
  call exchange_messages
  
end subroutine update_secondbody
!^CFG END SECONDBODY
