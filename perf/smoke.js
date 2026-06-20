import { options as mixedCrudOptions } from './mixed-crud.js';

export { default } from './mixed-crud.js';

mixedCrudOptions.scenarios.mixed_crud.stages = [
  { duration: '10s', target: 100 },
  { duration: '20s', target: 100 },
  { duration: '10s', target: 0 },
];

export const options = mixedCrudOptions;
