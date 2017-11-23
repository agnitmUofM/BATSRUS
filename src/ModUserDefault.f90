!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModUser
  ! This is the default user module which contains empty methods defined
  ! in ModUserEmpty.f90

  use ModUserEmpty

  include 'user_module.h' ! list of public methods

  real,              parameter :: VersionUserModule = 1.0
  character (len=*), parameter :: NameUserModule = 'DEFAULT EMPTY ROUTINES'

contains
  !============================================================================

  subroutine init_mod_user
  end subroutine init_mod_user

  !============================================================================

  subroutine clean_mod_user
  end subroutine clean_mod_user
end module ModUser
!==============================================================================
